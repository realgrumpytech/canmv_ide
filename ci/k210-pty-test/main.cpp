// Exercises the real K210 ISP handshake (K210RamBurner) and QSerialPort
// against a pseudo-terminal. No K210 board is attached.
//
// The IDE decides "serial vs TCP" with QSerialPortInfo::isValid(), and a pty
// is not a listed serial port, so the burner object is driven over a TCP
// loopback that uses the same read/write/SLIP code. A second step opens the
// pty with QSerialPort itself (the class the IDE uses for /dev/cu.*) and
// exchanges the same greeting bytes, including baud and DTR/RTS calls.

#include <QCoreApplication>
#include <QElapsedTimer>
#include <QSerialPort>
#include <QThread>

#include <arpa/inet.h>
#include <netinet/in.h>
#include <sys/socket.h>
#include <sys/select.h>

#include <cstring>
#include <iostream>

#include <fcntl.h>
#include <termios.h>
#include <unistd.h>

// k210_burn/download/util.h is on the include path, so <util.h> would pick
// that up instead of the system header that declares openpty.
struct winsize;
extern "C" int openpty(int *amaster, int *aslave, char *name,
                       struct termios *termp, struct winsize *winp);

#include "k210burnRam.h"

static int fail(const char *msg)
{
    std::cerr << "FAIL: " << msg << std::endl;
    return 1;
}

// Independent CRC-32 (ISO-HDLC / zlib), unsigned bytes only.
static quint32 referenceCrc32(const QByteArray &data)
{
    quint32 crc = 0xffffffffu;
    for (int i = 0; i < data.size(); ++i) {
        crc ^= static_cast<unsigned char>(data.at(i));
        for (int b = 0; b < 8; ++b)
            crc = (crc >> 1) ^ (0xedb88320u & (0u - (crc & 1u)));
    }
    return crc ^ 0xffffffffu;
}

int main(int argc, char **argv)
{
    QCoreApplication app(argc, argv);

    QByteArray word;
    serializeLong(word, 0x12345678);
    if (word.size() != 4 || static_cast<unsigned char>(word.at(0)) != 0x78
        || static_cast<unsigned char>(word.at(1)) != 0x56
        || static_cast<unsigned char>(word.at(2)) != 0x34
        || static_cast<unsigned char>(word.at(3)) != 0x12) {
        return fail("serializeLong is not little-endian");
    }
    QByteArray round = word;
    if (deserializeLong(round) != 0x12345678)
        return fail("deserializeLong did not round-trip");

    QByteArray high;
    high.append(char(0x00));
    high.append(char(0xff));
    high.append(char(0x80));
    high.append("k210");
    if (crc32(high) != referenceCrc32(high))
        return fail("crc32 disagrees with an unsigned-byte reference (signed char?)");

    const int listenFd = ::socket(AF_INET, SOCK_STREAM, 0);
    if (listenFd < 0)
        return fail("socket");
    sockaddr_in addr;
    std::memset(&addr, 0, sizeof(addr));
    addr.sin_family = AF_INET;
    addr.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    addr.sin_port = 0;
    if (::bind(listenFd, reinterpret_cast<sockaddr *>(&addr), sizeof(addr)) != 0)
        return fail("bind");
    if (::listen(listenFd, 1) != 0)
        return fail("listen");
    socklen_t addrLen = sizeof(addr);
    if (::getsockname(listenFd, reinterpret_cast<sockaddr *>(&addr), &addrLen) != 0)
        return fail("getsockname");
    const quint16 tcpPort = ntohs(addr.sin_port);

    QThread *emulator = QThread::create([listenFd] {
        const int client = ::accept(listenFd, nullptr, nullptr);
        if (client < 0)
            return;
        QByteArray buf;
        unsigned char b = 0;
        QElapsedTimer timer;
        timer.start();
        while (timer.elapsed() < 8000) {
            fd_set fds;
            FD_ZERO(&fds);
            FD_SET(client, &fds);
            timeval tv;
            tv.tv_sec = 0;
            tv.tv_usec = 50000;
            if (select(client + 1, &fds, nullptr, nullptr, &tv) <= 0)
                continue;
            if (::read(client, &b, 1) != 1)
                break;
            buf.append(char(b));
            if (b == 0xc0 && buf.count(char(0xc0)) >= 2) {
                const int opIndex = buf.indexOf(char(0xc0)) + 1;
                const unsigned char op = static_cast<unsigned char>(buf.at(opIndex));
                const unsigned char packet[] = {0xc0, static_cast<unsigned char>(op == 0xc3 ? 0xc3 : 0xc2), 0xe0, 0x00, 0xc0};
                if (::write(client, packet, sizeof(packet)) != (ssize_t)sizeof(packet))
                    break;
                buf.clear();
                if (op == 0xc3)
                    break;
            }
        }
        ::close(client);
    });
    emulator->start();

    const QString name = QStringLiteral("k210:127.0.0.1:%1").arg(tcpPort);
    OpenMVPluginSerialPort_thing link(name);
    link.setReadBufferSize(1000000);
    if (!link.open(QIODevice::ReadWrite))
        return fail(qPrintable(QStringLiteral("open tcp link: ") + link.errorString()));

    K210RamBurner burner;
    const burnResp_t hello = burner.handShake(&link);
    if (hello.op != ISP_NOP || hello.reason != ISP_RET_OK) {
        std::cerr << "handshake op=" << int(hello.op) << " reason=" << int(hello.reason)
                  << " text=" << qPrintable(hello.text) << std::endl;
        return fail("K210RamBurner::handShake did not get ISP_NOP/OK");
    }

    const QByteArray chunk("canmv-k210");
    const burnResp_t wrote = burner.memoryWrite(&link, 0x80000000, chunk.size(), chunk);
    if (wrote.op != ISP_MEMORY_WRITE || wrote.reason != ISP_RET_OK)
        return fail("K210RamBurner::memoryWrite did not get OK");

    emulator->wait(3000);
    delete emulator;

    int master = -1;
    int slave = -1;
    if (openpty(&master, &slave, nullptr, nullptr, nullptr) != 0)
        return fail("openpty");
    const QString slaveName = QString::fromLocal8Bit(ttyname(slave));
    std::cerr << "pty slave " << qPrintable(slaveName) << std::endl;

    QThread *ptyEmu = QThread::create([master] {
        unsigned char b = 0;
        QByteArray buf;
        QElapsedTimer timer;
        timer.start();
        while (timer.elapsed() < 5000) {
            fd_set fds;
            FD_ZERO(&fds);
            FD_SET(master, &fds);
            timeval tv;
            tv.tv_sec = 0;
            tv.tv_usec = 50000;
            if (select(master + 1, &fds, nullptr, nullptr, &tv) > 0 && read(master, &b, 1) == 1) {
                buf.append(char(b));
                if (b == 0xc0 && buf.size() > 2) {
                    const unsigned char packet[] = {0xc0, 0xc2, 0xe0, 0x00, 0xc0};
                    if (::write(master, packet, sizeof(packet)) != (ssize_t)sizeof(packet))
                        return;
                    return;
                }
            }
        }
    });
    ptyEmu->start();

    QSerialPort serial;
    serial.setPortName(slaveName);
    serial.setBaudRate(115200);
    if (!serial.open(QIODevice::ReadWrite)) {
        std::cerr << "QSerialPort open: " << qPrintable(serial.errorString()) << std::endl;
        return fail("QSerialPort could not open the pty");
    }
    serial.setBaudRate(1500000);
    serial.setDataTerminalReady(false);
    serial.setRequestToSend(true);
    serial.setDataTerminalReady(true);
    serial.setRequestToSend(false);

    const QByteArray greeting = QByteArray::fromHex("c0c2000000000000000000000000c0");
    if (serial.write(greeting) != greeting.size() || !serial.waitForBytesWritten(1000))
        return fail("QSerialPort did not write the ISP greeting");
    if (!serial.waitForReadyRead(2000))
        return fail("QSerialPort did not receive the emulated ISP reply");
    const QByteArray got = serial.readAll();
    if (!got.contains(QByteArray::fromHex("c2e0")))
        return fail("pty reply was not ISP_NOP/OK");

    ptyEmu->wait(2000);
    delete ptyEmu;
    ::close(master);
    ::close(slave);

    std::cout << "K210 protocol test passed" << std::endl;
    return 0;
}
