/************************************************************************
 *
 *  WaveDSP - Help window (macOS)
 *
 *  FILE:      HelpWindow.h
 *
 *  PURPOSE:   A resizable, modeless window that shows an application's help
 *             with sized, coloured headings and shortcut tables: the Mac
 *             counterpart of the Windows helpwindow.h, taking the same
 *             markup. MacMDV, MSap, MPlayer and MVista carry identical
 *             copies.
 *
 *  Update:    2026.11 Created
 *
 ************************************************************************/

#pragma once

#import <Cocoa/Cocoa.h>

namespace wavedsp {

// Nil colours fall back to the system's, which follow light and dark mode.
struct HelpTheme {
    NSColor* background = nil;
    NSColor* text = nil;
    NSColor* title = nil;    // the "# " title
    NSColor* heading = nil;  // "## " sections and the keys in shortcut tables
    NSColor* muted = nil;    // "> " notes
    NSColor* rule = nil;     // shading of every other shortcut row
    NSAppearance* appearance = nil;  // nil follows the application
};

// Opens the help window, or brings the open one forward with the new text
// and colours. The markup has one item per line:
//   "# text"        title                 "## text"   section heading
//   "### text"      subheading            "- text"    bullet
//   "> text"        note                  "keys\ttext" shortcut row; adjacent rows form a table
//   anything else is a paragraph; blank lines are ignored. "**text**" is bold.
void ShowHelp(NSWindow* owner, NSString* caption, NSString* markup, const HelpTheme& theme);

// The styled text that the markup becomes.
NSAttributedString* HelpText(NSString* markup, const HelpTheme& theme);

// The help window when it is open, otherwise nil.
NSWindow* OpenHelpWindow();

}  // namespace wavedsp
