#import <AppKit/AppKit.h>
#import "GTK4NativeWindow.h"
#include <gtk/gtk.h>

static void pump(double seconds)
{
  NSDate *end=[NSDate dateWithTimeIntervalSinceNow:seconds];
  while(end.timeIntervalSinceNow>0) {
    for(int i=0;i<64 && g_main_context_pending(NULL);i++) g_main_context_iteration(NULL,FALSE);
    NSEvent *event=[NSApp nextEventMatchingMask:NSAnyEventMask
      untilDate:[NSDate dateWithTimeIntervalSinceNow:.005] inMode:NSDefaultRunLoopMode dequeue:YES];
    if(event) [NSApp sendEvent:event];
    [NSApp updateWindows];
  }
}
static void painted(GdkFrameClock *clock,gpointer data) { (*(NSUInteger *)data)++; }
int main(void)
{
  NSAutoreleasePool *pool=[NSAutoreleasePool new];
  [NSApplication sharedApplication]; [NSApp finishLaunching];
  NSMenu *menu=[[[NSMenu alloc] initWithTitle:@"Main"] autorelease];
  [menu addItemWithTitle:@"File" action:NULL keyEquivalent:@""];
  [NSApp setMainMenu:menu];
  NSWindow *window=[[NSWindow alloc] initWithContentRect:NSMakeRect(40,40,880,400)
    styleMask:NSTitledWindowMask|NSClosableWindowMask|NSResizableWindowMask backing:NSBackingStoreBuffered defer:NO];
  [window setReleasedWhenClosed:NO];
  NSSplitView *split=[[[NSSplitView alloc] initWithFrame:[window.contentView bounds]] autorelease];
  split.vertical=YES; split.autoresizingMask=NSViewWidthSizable|NSViewHeightSizable;
  [window.contentView addSubview:split];
  NSBox *box=[[[NSBox alloc] initWithFrame:NSMakeRect(0,0,600,400)] autorelease];
  box.title=@"Idle controls"; box.autoresizingMask=NSViewWidthSizable|NSViewHeightSizable;
  [split addSubview:box];
  NSTextField *label=[[[NSTextField alloc] initWithFrame:NSMakeRect(20,200,250,28)] autorelease];
  label.editable=NO; label.bezeled=NO; label.drawsBackground=NO; label.stringValue=@"No content changes";
  [box.contentView addSubview:label];
  NSButton *button=[[[NSButton alloc] initWithFrame:NSMakeRect(20,140,180,34)] autorelease];
  button.title=@"Unchanged action"; [box.contentView addSubview:button];
  NSPopUpButton *pullDown=[[[NSPopUpButton alloc] initWithFrame:NSMakeRect(20,80,180,34) pullsDown:YES] autorelease];
  [pullDown addItemsWithTitles:@[@"+",@"Add item"]];
  [box.contentView addSubview:pullDown];
  NSScrollView *scroll=[[[NSScrollView alloc] initWithFrame:NSMakeRect(300,20,240,260)] autorelease];
  scroll.hasVerticalScroller=YES;
  NSView *document=[[[NSView alloc] initWithFrame:NSMakeRect(0,0,220,500)] autorelease];
  scroll.documentView=document; [box.contentView addSubview:scroll];
  NSScrollView *editorScroll=[[[NSScrollView alloc] initWithFrame:NSMakeRect(610,0,270,400)] autorelease];
  editorScroll.hasVerticalScroller=YES;
  NSTextView *editor=[[[NSTextView alloc] initWithFrame:NSMakeRect(0,0,250,500)] autorelease];
  editor.editable=NO; editor.string=@"Idle editor content";
  editorScroll.documentView=editor; [split addSubview:editorScroll]; [split adjustSubviews];
  [window makeKeyAndOrderFront:nil]; pump(1);
  GTK4NativeWindowDecorationView *host=(id)[(NSView *)window.contentView superview];
  NSCAssert([host isKindOfClass:GTK4NativeWindowDecorationView.class],@"native GTK window");
  GdkFrameClock *clock=gtk_widget_get_frame_clock(host->_host);
  NSUInteger frames=0;
  gulong signal=g_signal_connect(clock,"after-paint",G_CALLBACK(painted),&frames);
  pump(1);
  NSUInteger pollingFrames=frames;
  host->_placing=YES; pump(.3); frames=0; pump(1);
  NSUInteger pausedFrames=frames;
  host->_placing=NO;
  NSLog(@"Idle GTK frames in one second: host synchronization=%lu, paused=%lu",pollingFrames,pausedFrames);
  frames=0;
  label.stringValue=@"Updated content still redraws";
  box.title=@"Updated group";
  [pullDown itemAtIndex:0].title=@"Actions";
  pump(.3);
  GtkWidget *nativeLabel=GTK4NativeWidgetForView(label);
  NSCAssert(GTK_IS_LABEL(nativeLabel) && !strcmp(gtk_label_get_text(GTK_LABEL(nativeLabel)),label.stringValue.UTF8String),
    @"model changes still reach native controls");
  GtkWidget *nativePullDown=GTK4NativeWidgetForView(pullDown);
  NSCAssert(GTK_IS_MENU_BUTTON(nativePullDown) && !strcmp(gtk_menu_button_get_label(GTK_MENU_BUTTON(nativePullDown)),"Actions"),
    @"changed pull-down titles still reach GTK");
  NSCAssert(frames>0,@"actual content changes request frames");
  frames=0; pump(1);
  NSUInteger settledFrames=frames;
  int oldWidth=gtk_widget_get_width(GTK4NativeWidgetForView(split));
  gtk_window_set_default_size(GTK_WINDOW(host->_host),gtk_widget_get_width(host->_host)+120,gtk_widget_get_height(host->_host)+80);
  pump(.3);
  NSCAssert(gtk_widget_get_width(GTK4NativeWidgetForView(split))>=oldWidth+100,@"GTK still lays out the resized content");
  NSLog(@"Idle GTK frames after content updates settle: %lu",settledFrames);
  g_signal_handler_disconnect(clock,signal);

  if(!getenv("GTK4_IDLE_MEASURE_ONLY")) NSCAssert(pollingFrames<=2 && pausedFrames<=2 && settledFrames<=2,@"idle native windows stop requesting frames");
  [window close]; [window release]; [pool drain]; return 0;
}
