# Compiles the real K210 ISP sources and drives them on arm64.
TEMPLATE = app
CONFIG += console c++11
CONFIG -= app_bundle
QT = core network serialport gui-private concurrent
DEFINES += QTCREATOR_UTILS_STATIC_LIB

INCLUDEPATH += \
    $$PWD/../../qt-creator/src/libs \
    $$PWD/../../qt-creator/src/plugins/openmv \
    $$PWD/../../qt-creator/src/plugins/openmv/k210_burn/download

HEADERS += \
    $$PWD/../../qt-creator/src/plugins/openmv/openmvpluginserialport.h \
    $$PWD/../../qt-creator/src/plugins/openmv/k210_burn/download/k210burnRam.h \
    $$PWD/../../qt-creator/src/plugins/openmv/k210_burn/download/util.h

SOURCES += \
    main.cpp \
    $$PWD/../../qt-creator/src/plugins/openmv/openmvpluginserialport.cpp \
    $$PWD/../../qt-creator/src/plugins/openmv/k210_burn/download/k210burnRam.cpp \
    $$PWD/../../qt-creator/src/plugins/openmv/k210_burn/download/util.cpp
