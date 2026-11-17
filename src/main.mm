/************************************************************************
 *
 *  MSap - Speech Analysis Program for macOS, AppKit port of WinSap
 *
 *  FILE:      main.mm
 *
 *  PURPOSE:   Entry point. Mirrors XSap src/main.cpp and WinSap
 *             src/common/main.cpp: build the application object and hand
 *             control to it. Any file named on the command line is passed
 *             through so the program can be started with tracks already
 *             loaded.
 *
 *  Update:    2026.1
 *
 ************************************************************************/

#include "MsapApp.h"

/*****************************************************************************
 * main
 *
 * Creates the application object and runs it. Everything that touches AppKit
 * lives behind MsapApp so this file stays trivially portable.
 *
 *****************************************************************************/
int main(int argc, char** argv)
{
    msap::MsapApp app;
    return app.run(argc, argv);
}
