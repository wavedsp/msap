/************************************************************************
 *
 *  MSap - Main Application Header
 *
 *  FILE:      MsapApp.h
 *
 *  PURPOSE:   The application class that owns the main window, the panels
 *             and the UI. Counterpart of WinSap src/x64/WinsapApp.h and
 *             XSap src/XsapApp.h.
 *
 *             Everything is hidden behind a pimpl so that the AppKit headers
 *             stay out of the rest of the program. Only the .mm files ever
 *             see Objective-C; the analysis core stays plain C++17.
 *
 *  Update:    2026.1
 *
 ************************************************************************/

#pragma once

#include <memory>

namespace msap {

class MsapApp {
public:
    MsapApp();
    ~MsapApp();

    MsapApp(const MsapApp&) = delete;
    MsapApp& operator=(const MsapApp&) = delete;

    int run(int argc, char** argv);

private:
    struct Impl;
    std::unique_ptr<Impl> impl_;
};

} // namespace msap
