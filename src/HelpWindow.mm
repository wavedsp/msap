/************************************************************************
 *
 *  WaveDSP - Help window (macOS)
 *
 *  FILE:      HelpWindow.mm
 *
 *  PURPOSE:   Turns the help markup (see HelpWindow.h) into attributed
 *             text and shows it in a read-only, selectable NSTextView that
 *             fills a resizable window. Shortcut rows are NSTextTable cells,
 *             so the tables reflow with the window. The arrow and page keys
 *             scroll the page; Escape closes it.
 *
 *  Update:    2026.11 Created
 *
 ************************************************************************/

#import "HelpWindow.h"

#include <algorithm>

@interface WaveDSPHelpTextView : NSTextView
@end

static NSMenuItem* FinderItem(NSTextFinderAction action)
{
    NSMenuItem* item = [[NSMenuItem alloc] initWithTitle:@"" action:NULL keyEquivalent:@""];
    item.tag = action;
    return item;
}

@implementation WaveDSPHelpTextView
- (void)cancelOperation:(id)sender
{
    (void)sender;
    // Escape hides the find bar first, then closes the window.
    NSScrollView* scroll = self.enclosingScrollView;
    if (scroll.findBarVisible) {
        [self performTextFinderAction:FinderItem(NSTextFinderActionHideFindInterface)];
        return;
    }
    [self.window performClose:nil];
}

// The applications give ⌘W, ⌘F, ⌘G, ⌘A and ⌘C their own meanings (MSap's
// ⌘W closes every file), so the help window takes these keys before the
// menu bar sees them, as the help window's own accelerators do on Windows.
- (BOOL)performKeyEquivalent:(NSEvent*)event
{
    if (event.window != self.window || !self.window.keyWindow) {
        return [super performKeyEquivalent:event];
    }
    const NSEventModifierFlags flags = event.modifierFlags & NSEventModifierFlagDeviceIndependentFlagsMask &
                                       (NSEventModifierFlagCommand | NSEventModifierFlagShift |
                                        NSEventModifierFlagOption | NSEventModifierFlagControl);
    NSString* key = event.charactersIgnoringModifiers.lowercaseString;
    const bool command = flags == NSEventModifierFlagCommand;
    const bool shiftCommand = flags == (NSEventModifierFlagCommand | NSEventModifierFlagShift);
    if (command && [key isEqualToString:@"w"]) {
        [self.window performClose:nil];
    } else if (command && [key isEqualToString:@"f"]) {
        [self performTextFinderAction:FinderItem(NSTextFinderActionShowFindInterface)];
    } else if ((command || shiftCommand) && [key isEqualToString:@"g"]) {
        [self performTextFinderAction:FinderItem(command ? NSTextFinderActionNextMatch
                                                         : NSTextFinderActionPreviousMatch)];
    } else if (command && [key isEqualToString:@"a"]) {
        [self selectAll:nil];
    } else if (command && [key isEqualToString:@"c"]) {
        [self copy:nil];
    } else {
        return [super performKeyEquivalent:event];
    }
    return YES;
}
@end

namespace wavedsp {
namespace {

NSWindow* helpWindow = nil;
WaveDSPHelpTextView* helpView = nil;

NSFont* Font(CGFloat size, NSFontWeight weight)
{
    return [NSFont systemFontOfSize:size weight:weight];
}

NSFont* Italic(NSFont* font)
{
    return [NSFontManager.sharedFontManager convertFont:font toHaveTrait:NSItalicFontMask];
}

NSMutableParagraphStyle* Paragraph(CGFloat before, CGFloat after, CGFloat lineHeight = 1.15)
{
    NSMutableParagraphStyle* style = [[NSMutableParagraphStyle alloc] init];
    style.paragraphSpacingBefore = before;
    style.paragraphSpacing = after;
    style.lineHeightMultiple = lineHeight;
    return style;
}

// Appends one line with "**text**" in the bold font.
void AppendInline(NSMutableAttributedString* out, NSString* text, NSFont* font, NSFont* bold, NSColor* color,
                  NSParagraphStyle* style)
{
    NSArray<NSString*>* parts = [text componentsSeparatedByString:@"**"];
    for (NSUInteger i = 0; i < parts.count; ++i) {
        if (parts[i].length == 0) {
            continue;
        }
        NSDictionary* attributes = @{
            NSFontAttributeName : i % 2 ? bold : font,
            NSForegroundColorAttributeName : color,
            NSParagraphStyleAttributeName : style,
        };
        [out appendAttributedString:[[NSAttributedString alloc] initWithString:parts[i] attributes:attributes]];
    }
    [out appendAttributedString:[[NSAttributedString alloc] initWithString:@"\n" attributes:@{
        NSFontAttributeName : font,
        NSParagraphStyleAttributeName : style,
    }]];
}

HelpTheme Resolved(const HelpTheme& theme)
{
    HelpTheme out = theme;
    out.background = theme.background ?: NSColor.textBackgroundColor;
    out.text = theme.text ?: NSColor.labelColor;
    out.title = theme.title ?: NSColor.controlAccentColor;
    out.heading = theme.heading ?: NSColor.controlAccentColor;
    out.muted = theme.muted ?: NSColor.secondaryLabelColor;
    out.rule = theme.rule ?: [NSColor colorWithName:@"WaveDSPHelpRule"
                                     dynamicProvider:^NSColor*(NSAppearance* appearance) {
                                         const BOOL dark = [appearance bestMatchFromAppearancesWithNames:@[
                                             NSAppearanceNameAqua, NSAppearanceNameDarkAqua
                                         ]] == NSAppearanceNameDarkAqua;
                                         return dark ? [NSColor colorWithWhite:1 alpha:0.07]
                                                     : [NSColor colorWithSRGBRed:0.94 green:0.955 blue:0.975 alpha:1];
                                     }];
    return out;
}

NSRect InitialFrame(NSWindow* owner)
{
    NSScreen* screen = owner.screen ?: NSScreen.mainScreen;
    const NSRect work = screen ? screen.visibleFrame : NSMakeRect(0, 0, 1280, 800);
    const CGFloat width = std::min<CGFloat>(640, NSWidth(work));
    const CGFloat height = std::min<CGFloat>(720, NSHeight(work));
    const NSRect around = owner ? owner.frame : work;
    CGFloat x = NSMidX(around) - width / 2;
    CGFloat y = NSMidY(around) - height / 2;
    x = std::max(NSMinX(work), std::min(x, NSMaxX(work) - width));
    y = std::max(NSMinY(work), std::min(y, NSMaxY(work) - height));
    return NSMakeRect(x, y, width, height);
}

}  // namespace

/*****************************************************************************
 * HelpText
 *
 * The sizes follow the Windows page, in Mac points. Shortcut keys take a
 * third of the column so the actions line up.
 *
 *****************************************************************************/
NSAttributedString* HelpText(NSString* markup, const HelpTheme& given)
{
    const HelpTheme theme = Resolved(given);
    NSFont* body = Font(13, NSFontWeightRegular);
    NSFont* bodyBold = Font(13, NSFontWeightSemibold);
    NSMutableAttributedString* out = [[NSMutableAttributedString alloc] init];
    NSTextTable* table = nil;
    NSUInteger rows = 0;
    bool first = true;
    for (NSString* raw in [markup componentsSeparatedByString:@"\n"]) {
        NSString* line = [raw hasSuffix:@"\r"] ? [raw substringToIndex:raw.length - 1] : raw;
        if (line.length == 0) {
            continue;
        }
        const NSRange tab = [line rangeOfString:@"\t"];
        const bool row = tab.location != NSNotFound;
        // Space above whatever follows a table, so it does not touch the last row.
        const CGFloat after = table != nil && !row ? 8 : 0;
        if ([line hasPrefix:@"# "]) {
            AppendInline(out, [line substringFromIndex:2], Font(24, NSFontWeightSemibold),
                         Font(24, NSFontWeightBold), theme.title, Paragraph(after + (first ? 4 : 12), 8, 1));
        } else if ([line hasPrefix:@"## "]) {
            AppendInline(out, [line substringFromIndex:3], Font(18, NSFontWeightSemibold),
                         Font(18, NSFontWeightBold), theme.heading, Paragraph(first ? 0 : 16, 5, 1));
        } else if ([line hasPrefix:@"### "]) {
            AppendInline(out, [line substringFromIndex:4], Font(14, NSFontWeightSemibold),
                         Font(14, NSFontWeightBold), theme.text, Paragraph(first ? 0 : 10, 4, 1));
        } else if ([line hasPrefix:@"- "]) {
            NSMutableParagraphStyle* style = Paragraph(after, 4);
            style.firstLineHeadIndent = 6;
            style.headIndent = 22;
            style.tabStops = @[ [[NSTextTab alloc] initWithTextAlignment:NSTextAlignmentLeft location:22 options:@{}] ];
            AppendInline(out, [@"\u2022\t" stringByAppendingString:[line substringFromIndex:2]], body, bodyBold,
                         theme.text, style);
        } else if ([line hasPrefix:@"> "]) {
            NSFont* note = Italic(Font(12, NSFontWeightRegular));
            AppendInline(out, [line substringFromIndex:2], note, Italic(Font(12, NSFontWeightSemibold)), theme.muted,
                         Paragraph(after + 2, 6));
        } else if (row) {
            if (table == nil) {
                table = [[NSTextTable alloc] init];
                table.numberOfColumns = 2;
                table.collapsesBorders = YES;
                table.layoutAlgorithm = NSTextTableAutomaticLayoutAlgorithm;
                [table setValue:100 type:NSTextBlockPercentageValueType forDimension:NSTextBlockWidth];
                rows = 0;
            } else {
                ++rows;
            }
            NSString* cells[2] = {[line substringToIndex:tab.location], [line substringFromIndex:NSMaxRange(tab)]};
            for (NSInteger column = 0; column < 2; ++column) {
                NSTextTableBlock* block = [[NSTextTableBlock alloc] initWithTable:table
                                                                      startingRow:static_cast<NSInteger>(rows)
                                                                          rowSpan:1
                                                                   startingColumn:column
                                                                       columnSpan:1];
                [block setValue:column == 0 ? 34 : 66 type:NSTextBlockPercentageValueType
                    forDimension:NSTextBlockWidth];
                [block setWidth:3 type:NSTextBlockAbsoluteValueType forLayer:NSTextBlockPadding edge:NSMinYEdge];
                [block setWidth:3 type:NSTextBlockAbsoluteValueType forLayer:NSTextBlockPadding edge:NSMaxYEdge];
                [block setWidth:8 type:NSTextBlockAbsoluteValueType forLayer:NSTextBlockPadding edge:NSMinXEdge];
                [block setWidth:8 type:NSTextBlockAbsoluteValueType forLayer:NSTextBlockPadding edge:NSMaxXEdge];
                // Every other row is shaded, starting with the first.
                if (rows % 2 == 0) {
                    block.backgroundColor = theme.rule;
                }
                NSMutableParagraphStyle* style = Paragraph(0, 0);
                style.textBlocks = @[ block ];
                AppendInline(out, cells[column], column == 0 ? Font(12.5, NSFontWeightSemibold) : Font(12.5, NSFontWeightRegular),
                             Font(12.5, NSFontWeightBold), column == 0 ? theme.heading : theme.text, style);
            }
        } else {
            AppendInline(out, line, body, bodyBold, theme.text, Paragraph(after, 6));
        }
        if (!row) {
            table = nil;
        }
        first = false;
    }
    return out;
}

NSWindow* OpenHelpWindow()
{
    return helpWindow.visible || helpWindow.miniaturized ? helpWindow : nil;
}

/*****************************************************************************
 * ShowHelp
 *
 * One window serves the whole application. It is modeless, so the
 * application can be used while reading, and the page starts at the top.
 *
 *****************************************************************************/
void ShowHelp(NSWindow* owner, NSString* caption, NSString* markup, const HelpTheme& theme)
{
    if (helpWindow == nil) {
        helpWindow = [[NSWindow alloc] initWithContentRect:InitialFrame(owner)
                                                 styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable |
                                                           NSWindowStyleMaskMiniaturizable |
                                                           NSWindowStyleMaskResizable
                                                   backing:NSBackingStoreBuffered
                                                     defer:NO];
        [helpWindow setFrame:InitialFrame(owner) display:NO];
        helpWindow.releasedWhenClosed = NO;
        helpWindow.minSize = NSMakeSize(360, 300);
        helpWindow.tabbingMode = NSWindowTabbingModeDisallowed;
        NSScrollView* scroll = [[NSScrollView alloc] initWithFrame:helpWindow.contentView.bounds];
        scroll.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
        scroll.hasVerticalScroller = YES;
        scroll.borderType = NSNoBorder;
        helpView = [[WaveDSPHelpTextView alloc] initWithFrame:scroll.contentView.bounds];
        helpView.autoresizingMask = NSViewWidthSizable;
        helpView.verticallyResizable = YES;
        helpView.horizontallyResizable = NO;
        helpView.textContainer.widthTracksTextView = YES;
        helpView.textContainerInset = NSMakeSize(20, 18);
        helpView.editable = NO;
        helpView.selectable = YES;
        helpView.richText = YES;
        helpView.usesFindBar = YES;
        helpView.incrementalSearchingEnabled = YES;
        scroll.documentView = helpView;
        helpWindow.contentView = scroll;
    }
    const HelpTheme resolved = Resolved(theme);
    helpWindow.title = caption;
    helpWindow.appearance = theme.appearance;
    helpView.backgroundColor = resolved.background;
    helpView.enclosingScrollView.backgroundColor = resolved.background;
    [helpView.textStorage setAttributedString:HelpText(markup, theme)];
    helpView.selectedRange = NSMakeRange(0, 0);
    [helpView scrollPoint:NSZeroPoint];
    if (helpWindow.miniaturized) {
        [helpWindow deminiaturize:nil];
    }
    [helpWindow makeKeyAndOrderFront:nil];
    [helpWindow makeFirstResponder:helpView];
}

}  // namespace wavedsp
