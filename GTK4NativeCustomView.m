#import "GTK4NativeCustomView.h"
#import <GNUstepGUI/GSNativeView.h>
#include <objc/runtime.h>

@interface GTK4CustomDrawing : NSObject <GSNativeEventSource>
{
@public
  NSView *source;
  GtkWidget *widget;
  CGFloat scale;
  NSRect dirty;
  NSBitmapImageRep *bitmap;
  NSGraphicsContext *context;
  GdkTexture *texture;
  GtkIMContext *input;
  guint button;
  int clicks;
  double startX, startY;
  BOOL dispatching;
  NSMutableArray *pendingEvents;
  BOOL windowContent;
}
- (void)snapshot:(GtkSnapshot *)snapshot;
- (void)deliver:(NSArray *)request;
- (void)mouse:(NSEventType)type x:(double)x y:(double)y controller:(GtkEventController *)controller;
- (void)key:(guint)keyval code:(guint)code state:(GdkModifierType)state up:(BOOL)up;
@end

typedef struct { GtkWidget parent; GTK4CustomDrawing *drawing; } GSAppKitWidget;
typedef struct { GtkWidgetClass parent; } GSAppKitWidgetClass;
G_DEFINE_TYPE(GSAppKitWidget, gs_appkit_widget, GTK_TYPE_WIDGET)
static void customMeasure(GtkWidget *widget, GtkOrientation orientation, int forSize,
  int *minimum, int *natural, int *minimumBaseline, int *naturalBaseline)
{
  GTK4CustomDrawing *drawing=((GSAppKitWidget *)widget)->drawing;
  NSSize intrinsic=[drawing->source intrinsicContentSize];
  CGFloat value=orientation==GTK_ORIENTATION_HORIZONTAL ? intrinsic.width : intrinsic.height;
  CGFloat frame=orientation==GTK_ORIENTATION_HORIZONTAL ? NSWidth(drawing->source.frame) : NSHeight(drawing->source.frame);
  *minimum=0; *natural=MAX(0,lround((value==NSViewNoIntrinsicMetric ? frame : value)*drawing->scale));
  if (minimumBaseline) *minimumBaseline=-1;
  if (naturalBaseline) *naturalBaseline=-1;
}
static void customAllocate(GtkWidget *widget,int width,int height,int baseline)
{
  GTK4CustomDrawing *drawing=((GSAppKitWidget *)widget)->drawing;
  if(drawing->windowContent) return;
  NSValue *expected=g_object_get_data(G_OBJECT(widget),"appkit-reflected-frame");
  if(!expected) expected=g_object_get_data(G_OBJECT(widget),"appkit-source-frame");
  if(expected && !NSEqualRects(drawing->source.frame,expected.rectValue)) return;
  NSSize size=NSMakeSize(width/drawing->scale,height/drawing->scale);
  if (!NSEqualSizes(drawing->source.frame.size,size)) [drawing->source setFrameSize:size];
}
static void customSnapshot(GtkWidget *widget,GtkSnapshot *snapshot)
{
  id bridge=g_object_get_data(G_OBJECT(widget),"appkit-bridge");
  if (bridge) [bridge performSelector:@selector(reflectContainer:) withObject:[NSValue valueWithPointer:widget]];
  [((GSAppKitWidget *)widget)->drawing snapshot:snapshot];
  for (GtkWidget *child=gtk_widget_get_first_child(widget);child;child=gtk_widget_get_next_sibling(child))
    gtk_widget_snapshot_child(widget,child,snapshot);
}
static void customDispose(GObject *object)
{
  GtkWidget *child;
  while ((child=gtk_widget_get_first_child(GTK_WIDGET(object)))) gtk_widget_unparent(child);
  G_OBJECT_CLASS(gs_appkit_widget_parent_class)->dispose(object);
}
static void customFinalize(GObject *object)
{
  [((GSAppKitWidget *)object)->drawing release];
  G_OBJECT_CLASS(gs_appkit_widget_parent_class)->finalize(object);
}
static void gs_appkit_widget_class_init(GSAppKitWidgetClass *cls)
{
  G_OBJECT_CLASS(cls)->dispose=customDispose; G_OBJECT_CLASS(cls)->finalize=customFinalize;
  GTK_WIDGET_CLASS(cls)->measure=customMeasure;
  GTK_WIDGET_CLASS(cls)->size_allocate=customAllocate;
  GTK_WIDGET_CLASS(cls)->snapshot=customSnapshot;
  gtk_widget_class_set_accessible_role(GTK_WIDGET_CLASS(cls),GTK_ACCESSIBLE_ROLE_GROUP);
}
static void gs_appkit_widget_init(GSAppKitWidget *widget)
{ gtk_widget_set_overflow(GTK_WIDGET(widget),GTK_OVERFLOW_HIDDEN); }

static NSUInteger modifiers(GdkModifierType state)
{
  return ((state&GDK_SHIFT_MASK)?NSShiftKeyMask:0) | ((state&GDK_CONTROL_MASK)?NSControlKeyMask:0)
    | ((state&GDK_ALT_MASK)?NSAlternateKeyMask:0) | ((state&(GDK_SUPER_MASK|GDK_META_MASK))?NSCommandKeyMask:0)
    | ((state&GDK_LOCK_MASK)?NSAlphaShiftKeyMask:0);
}
static NSEventType pointerType(guint button,BOOL up,BOOL drag)
{
  return button==1 ? (up?NSLeftMouseUp:drag?NSLeftMouseDragged:NSLeftMouseDown)
    : button==3 ? (up?NSRightMouseUp:drag?NSRightMouseDragged:NSRightMouseDown)
    : (up?NSOtherMouseUp:drag?NSOtherMouseDragged:NSOtherMouseDown);
}
static void motion(GtkEventControllerMotion *controller,double x,double y,gpointer data)
{
  GTK4CustomDrawing *drawing=data;
  if (!drawing->button && gtk_widget_pick(drawing->widget,x,y,GTK_PICK_DEFAULT)==drawing->widget)
    [drawing mouse:NSMouseMoved x:x y:y controller:GTK_EVENT_CONTROLLER(controller)];
}
static void entered(GtkEventControllerMotion *controller,double x,double y,gpointer data)
{ [(GTK4CustomDrawing *)data mouse:NSMouseEntered x:x y:y controller:GTK_EVENT_CONTROLLER(controller)]; }
static void exited(GtkEventControllerMotion *controller,gpointer data)
{ [(GTK4CustomDrawing *)data mouse:NSMouseExited x:0 y:0 controller:GTK_EVENT_CONTROLLER(controller)]; }
static void pressed(GtkGestureClick *gesture,int count,double x,double y,gpointer data)
{
  GTK4CustomDrawing *drawing=data;
  // GTK has already hit-tested the tree. A child's event belongs to that child,
  // even though gesture controllers also observe ancestor propagation.
  if (gtk_widget_pick(drawing->widget,x,y,GTK_PICK_DEFAULT)!=drawing->widget) {
    gtk_gesture_set_state(GTK_GESTURE(gesture),GTK_EVENT_SEQUENCE_DENIED); return;
  }
  drawing->button=gtk_gesture_single_get_current_button(GTK_GESTURE_SINGLE(gesture)); drawing->clicks=count;
  if(drawing->windowContent) gtk_widget_grab_focus(drawing->widget);
  else if ([drawing->source acceptsFirstResponder]) {
    [drawing->source.window makeFirstResponder:drawing->source];
    gtk_widget_grab_focus(drawing->widget);
  }
  gtk_gesture_set_state(GTK_GESTURE(gesture),GTK_EVENT_SEQUENCE_CLAIMED);
  [drawing mouse:pointerType(drawing->button,NO,NO) x:x y:y controller:GTK_EVENT_CONTROLLER(gesture)];
}
static void released(GtkGestureClick *gesture,int count,double x,double y,gpointer data)
{
  GTK4CustomDrawing *drawing=data;
  guint button=drawing->button;
  if (!button) return;
  drawing->button=0;
  [drawing mouse:pointerType(button,YES,NO) x:x y:y controller:GTK_EVENT_CONTROLLER(gesture)];
}
static void dragBegin(GtkGestureDrag *gesture,double x,double y,gpointer data)
{ GTK4CustomDrawing *drawing=data; drawing->startX=x; drawing->startY=y; }
static void dragUpdate(GtkGestureDrag *gesture,double x,double y,gpointer data)
{
  GTK4CustomDrawing *drawing=data;
  if (drawing->button) [drawing mouse:pointerType(drawing->button,NO,YES)
    x:drawing->startX+x y:drawing->startY+y controller:GTK_EVENT_CONTROLLER(gesture)];
}
static gboolean keyPressed(GtkEventControllerKey *controller,guint key,guint code,GdkModifierType state,gpointer data)
{
  GTK4CustomDrawing *drawing=data;
  GdkEvent *event=gtk_event_controller_get_current_event(GTK_EVENT_CONTROLLER(controller));
  if (key==GDK_KEY_Tab || key==GDK_KEY_ISO_Left_Tab) return FALSE;
  if (drawing->input && event && gtk_im_context_filter_keypress(drawing->input,event)) return TRUE;
  [drawing key:key code:code state:state up:NO]; return TRUE;
}
static void keyReleased(GtkEventControllerKey *controller,guint key,guint code,GdkModifierType state,gpointer data)
{ [(GTK4CustomDrawing *)data key:key code:code state:state up:YES]; }
static void focusEnter(GtkEventControllerFocus *controller,gpointer data)
{
  GTK4CustomDrawing *drawing=data;
  if (drawing->input) gtk_im_context_focus_in(drawing->input);
  if (!drawing->windowContent && drawing->source.window.firstResponder!=drawing->source) [drawing->source.window makeFirstResponder:drawing->source];
}
static void focusLeave(GtkEventControllerFocus *controller,gpointer data)
{ GTK4CustomDrawing *drawing=data; if (drawing->input) gtk_im_context_focus_out(drawing->input); }
static void commit(GtkIMContext *input,const char *text,gpointer data)
{
  GTK4CustomDrawing *drawing=[(id)data retain];
  @try {
    id target=drawing->windowContent ? drawing->source.window.firstResponder : drawing->source;
    if([target respondsToSelector:@selector(insertText:)]) [target insertText:[NSString stringWithUTF8String:text]];
  }
  @finally { [drawing release]; }
}

static gboolean windowScrolled(GtkEventControllerScroll *controller,double dx,double dy,gpointer data)
{
  GTK4CustomDrawing *drawing=data;
  if(!drawing->source) return FALSE;
  GdkEvent *event=gtk_event_controller_get_current_event(GTK_EVENT_CONTROLLER(controller));
  double x,y,tx,ty;
  if(!event || !gdk_event_get_position(event,&x,&y)) return FALSE;
  GtkNative *native=gtk_widget_get_native(drawing->widget);
  gtk_native_get_surface_transform(native,&tx,&ty);
  graphene_point_t position=GRAPHENE_POINT_INIT(x-tx,y-ty),local;
  if(!gtk_widget_compute_point(GTK_WIDGET(native),drawing->widget,&position,&local)) return FALSE;
  NSRect bounds=drawing->source.bounds;
  NSPoint point=NSMakePoint(NSMinX(bounds)+local.x/MAX(1,gtk_widget_get_width(drawing->widget))*NSWidth(bounds),
    NSMinY(bounds)+(drawing->source.isFlipped?local.y/MAX(1,gtk_widget_get_height(drawing->widget)):1-local.y/MAX(1,gtk_widget_get_height(drawing->widget)))*NSHeight(bounds));
  GdkModifierType state=gtk_event_controller_get_current_event_state(GTK_EVENT_CONTROLLER(controller));
  if(gtk_event_controller_scroll_get_unit(controller)==GDK_SCROLL_UNIT_SURFACE) { dx/=10; dy/=10; }
  NSEvent *wheel=[NSEvent mouseEventWithType:NSScrollWheel location:[drawing->source convertPoint:point toView:nil]
    modifierFlags:modifiers(state) timestamp:g_get_monotonic_time()/1e6 windowNumber:drawing->source.window.windowNumber
    context:nil eventNumber:0 clickCount:0 pressure:0 buttonNumber:0 deltaX:dx deltaY:-dy deltaZ:0];
  [NSApp postEvent:wheel atStart:NO];
  return TRUE;
}

BOOL GTK4NativeCanWrapView(NSView *view)
{
  // Framework text, table, GL and scroll implementations need dedicated adapters.
  // A subclass which supplies its own GTK widget uses that explicit adapter.
  if ([view respondsToSelector:@selector(gtk4NativeWidget)]) return NO;
  if ([view isKindOfClass:[NSTextField class]] || [view isKindOfClass:[NSTextView class]] || [view isKindOfClass:[NSTableView class]]
      || [view isKindOfClass:[NSScrollView class]] || [view isKindOfClass:[NSClipView class]]
      || [view isKindOfClass:[NSOpenGLView class]]) return NO;
  NSBundle *framework=[NSBundle bundleForClass:[NSView class]];
  if([NSBundle bundleForClass:view.class]==framework) return NO;
  // A subclass of a specialized framework container still needs that container's
  // adapter. Inherited AppKit layout must not silently become fixed GTK frames.
  Class base=view.class;
  while(base && [NSBundle bundleForClass:base]!=framework) base=class_getSuperclass(base);
  return base==[NSView class] || base==[NSTableCellView class] || [view isKindOfClass:[NSControl class]];
}
BOOL GTK4NativeIsCustomView(GtkWidget *widget)
{ return widget && G_TYPE_CHECK_INSTANCE_TYPE(widget,gs_appkit_widget_get_type()); }
void GTK4NativeCustomViewInvalidate(GtkWidget *widget,NSRect rect)
{
  if (!GTK4NativeIsCustomView(widget)) return;
  GTK4CustomDrawing *drawing=((GSAppKitWidget *)widget)->drawing;
  drawing->dirty=NSUnionRect(drawing->dirty,NSIntersectionRect(rect,drawing->source.bounds));
  gtk_widget_queue_draw(widget);
}
GtkWidget *GTK4NativeCustomViewNew(NSView *view,CGFloat scale)
{
  GtkWidget *widget=g_object_new(gs_appkit_widget_get_type(),NULL);
  GTK4CustomDrawing *drawing=[GTK4CustomDrawing new];
  drawing->pendingEvents=[NSMutableArray new];
  drawing->source=[view retain]; drawing->widget=widget; drawing->scale=scale; drawing->dirty=view.bounds;
  ((GSAppKitWidget *)widget)->drawing=drawing;
  g_object_set_data(G_OBJECT(widget),"appkit-custom-wrapper",drawing);
  gtk_widget_set_focusable(widget,[view acceptsFirstResponder]);
  GtkEventController *move=gtk_event_controller_motion_new();
  g_signal_connect(move,"motion",G_CALLBACK(motion),drawing);
  g_signal_connect(move,"enter",G_CALLBACK(entered),drawing); g_signal_connect(move,"leave",G_CALLBACK(exited),drawing);
  gtk_widget_add_controller(widget,move);
  GtkGesture *click=gtk_gesture_click_new(), *drag=gtk_gesture_drag_new();
  gtk_gesture_single_set_button(GTK_GESTURE_SINGLE(click),0); gtk_gesture_single_set_button(GTK_GESTURE_SINGLE(drag),0);
  g_signal_connect(click,"pressed",G_CALLBACK(pressed),drawing); g_signal_connect(click,"released",G_CALLBACK(released),drawing);
  g_signal_connect(drag,"drag-begin",G_CALLBACK(dragBegin),drawing); g_signal_connect(drag,"drag-update",G_CALLBACK(dragUpdate),drawing);
  gtk_widget_add_controller(widget,GTK_EVENT_CONTROLLER(click)); gtk_widget_add_controller(widget,GTK_EVENT_CONTROLLER(drag));
  gtk_gesture_group(click,drag);
  GtkEventController *key=gtk_event_controller_key_new();
  g_signal_connect(key,"key-pressed",G_CALLBACK(keyPressed),drawing); g_signal_connect(key,"key-released",G_CALLBACK(keyReleased),drawing);
  gtk_widget_add_controller(widget,key);
  GtkEventController *focus=gtk_event_controller_focus_new();
  g_signal_connect(focus,"enter",G_CALLBACK(focusEnter),drawing); g_signal_connect(focus,"leave",G_CALLBACK(focusLeave),drawing);
  gtk_widget_add_controller(widget,focus);
  if ([view respondsToSelector:@selector(insertText:)] && class_getMethodImplementation(view.class,@selector(insertText:))
      != class_getMethodImplementation([NSResponder class],@selector(insertText:))) {
    drawing->input=gtk_im_multicontext_new(); gtk_im_context_set_client_widget(drawing->input,widget);
    g_signal_connect(drawing->input,"commit",G_CALLBACK(commit),drawing);
  }
  return widget;
}

GtkWidget *GTK4NativeWindowContentNew(NSView *view,CGFloat scale)
{
  GtkWidget *widget=GTK4NativeCustomViewNew(view,scale);
  GTK4CustomDrawing *drawing=((GSAppKitWidget *)widget)->drawing;
  drawing->windowContent=YES;
  /* The host already owns this widget. Avoid retaining the host through its
   * drawing source; detach before destroying the GTK tree. */
  [drawing->source release];
  drawing->input=gtk_im_multicontext_new(); gtk_im_context_set_client_widget(drawing->input,widget);
  g_signal_connect(drawing->input,"commit",G_CALLBACK(commit),drawing);
  GtkEventController *scroll=gtk_event_controller_scroll_new(GTK_EVENT_CONTROLLER_SCROLL_BOTH_AXES);
  g_signal_connect(scroll,"scroll",G_CALLBACK(windowScrolled),drawing);
  gtk_widget_add_controller(widget,scroll);
  gtk_widget_set_focusable(widget,TRUE);
  return widget;
}
void GTK4NativeWindowContentDetach(GtkWidget *widget)
{
  if(GTK4NativeIsCustomView(widget)) ((GSAppKitWidget *)widget)->drawing->source=nil;
}

static void drawWindowSubtree(NSView *view,NSRect rect)
{
  if([view isHidden]) return;
  if(GSNativeViewPeerForView(view)) return;
  if([view isKindOfClass:[NSTableView class]] && [view valueForKey:@"_nativeTableView"]) return;
  NSGraphicsContext *context=[NSGraphicsContext currentContext];
  [context lockFocusView:view inRect:rect];
  @try {
    GSDrawNativeView(view,rect);
    for(NSView *child in [[view.subviews copy] autorelease]) {
      NSRect local=NSIntersectionRect([child convertRect:rect fromView:view],child.visibleRect);
      if(NSIsEmptyRect(local)) continue;
      NSPoint origin=[child convertPoint:NSZeroPoint toView:view];
      NSPoint x=[child convertPoint:NSMakePoint(1,0) toView:view],y=[child convertPoint:NSMakePoint(0,1) toView:view];
      NSAffineTransform *transform=[NSAffineTransform transform];
      [transform setTransformStruct:(NSAffineTransformStruct){x.x-origin.x,x.y-origin.y,y.x-origin.x,y.y-origin.y,origin.x,origin.y}];
      [NSGraphicsContext saveGraphicsState];
      @try { [transform concat]; NSRectClip(local); drawWindowSubtree(child,local); }
      @finally { [NSGraphicsContext restoreGraphicsState]; }
    }
  } @finally { [context unlockFocusView:view needsFlush:NO]; }
}

@implementation GTK4CustomDrawing
- (void)snapshot:(GtkSnapshot *)snapshot
{
  if(!source) return;
  int width=gtk_widget_get_width(widget),height=gtk_widget_get_height(widget);
  int backing=MAX(1,gtk_widget_get_scale_factor(widget));
  if (width<=0 || height<=0 || NSIsEmptyRect(source.bounds)) return;
  if (!bitmap || bitmap.pixelsWide!=width*backing || bitmap.pixelsHigh!=height*backing) {
    [context release]; context=nil; [bitmap release];
    bitmap=[[NSBitmapImageRep alloc] initWithBitmapDataPlanes:NULL pixelsWide:width*backing pixelsHigh:height*backing
      bitsPerSample:8 samplesPerPixel:4 hasAlpha:YES isPlanar:NO colorSpaceName:NSDeviceRGBColorSpace bytesPerRow:0 bitsPerPixel:32];
    memset(bitmap.bitmapData,0,bitmap.bytesPerRow*bitmap.pixelsHigh);
    context=[[NSGraphicsContext graphicsContextWithBitmapImageRep:bitmap] retain];
    dirty=source.bounds;
  }
  if (!NSIsEmptyRect(dirty) || !texture) {
    NSRect rect=NSIsEmptyRect(dirty)?source.bounds:dirty; dirty=NSZeroRect;
    NSGraphicsContext *previous=[NSGraphicsContext currentContext];
    [NSGraphicsContext setCurrentContext:context]; [NSGraphicsContext saveGraphicsState];
    [context lockFocusView:source inRect:rect];
    @try {
      NSAffineTransform *transform=[NSAffineTransform transform];
      if (source.isFlipped) { [transform translateXBy:0 yBy:height*backing]; }
      [transform scaleXBy:width*backing/NSWidth(source.bounds) yBy:(source.isFlipped?-1:1)*height*backing/NSHeight(source.bounds)];
      [transform translateXBy:-NSMinX(source.bounds) yBy:-NSMinY(source.bounds)]; [transform concat];
      NSRectClip(rect); NSRectFillUsingOperation(rect,NSCompositeClear);
      if(windowContent) drawWindowSubtree(source,rect); else GSDrawNativeView(source,rect);
    } @finally {
      [context unlockFocusView:source needsFlush:NO];
      [NSGraphicsContext restoreGraphicsState]; [context flushGraphics]; [NSGraphicsContext setCurrentContext:previous];
    }
    GBytes *bytes=g_bytes_new(bitmap.bitmapData,bitmap.bytesPerRow*bitmap.pixelsHigh);
    GdkTexture *next=gdk_memory_texture_new((int)bitmap.pixelsWide,(int)bitmap.pixelsHigh,
      GDK_MEMORY_R8G8B8A8_PREMULTIPLIED,bytes,bitmap.bytesPerRow);
    g_bytes_unref(bytes); if (texture) g_object_unref(texture); texture=next;
  }
  graphene_rect_t rect=GRAPHENE_RECT_INIT(0,0,width,height);
  gtk_snapshot_append_texture(snapshot,texture,&rect);
}
- (void)mouse:(NSEventType)type x:(double)x y:(double)y controller:(GtkEventController *)controller
{
  [self retain];
  @try {
    NSRect bounds=source.bounds;
    NSPoint local=NSMakePoint(NSMinX(bounds)+x/MAX(1,gtk_widget_get_width(widget))*NSWidth(bounds),
      NSMinY(bounds)+(source.isFlipped?y/MAX(1,gtk_widget_get_height(widget)):1-y/MAX(1,gtk_widget_get_height(widget)))*NSHeight(bounds));
    NSPoint location=[source convertPoint:local toView:nil];
    GdkModifierType state=gtk_event_controller_get_current_event_state(controller);
    NSEvent *event;
    NSInteger eventButton=(type==NSRightMouseDown || type==NSRightMouseUp || type==NSRightMouseDragged)?1
      :(type==NSOtherMouseDown || type==NSOtherMouseUp || type==NSOtherMouseDragged)?(button>3?button-1:2):0;
    if (type==NSMouseEntered || type==NSMouseExited)
      event=[NSEvent enterExitEventWithType:type location:location modifierFlags:modifiers(state)
        timestamp:g_get_monotonic_time()/1e6 windowNumber:source.window.windowNumber context:nil eventNumber:0 trackingNumber:0 userData:NULL];
    else event=[NSEvent mouseEventWithType:type location:location modifierFlags:modifiers(state)
      timestamp:g_get_monotonic_time()/1e6 windowNumber:source.window.windowNumber context:nil eventNumber:0
      clickCount:clicks pressure:button?1:0 buttonNumber:eventButton deltaX:0 deltaY:0 deltaZ:0];
    /* Window input belongs to AppKit's event queue. Dispatching mouseDown
     * from a run-loop performer keeps that performer active throughout split
     * tracking, preventing the autodisplay performers from running until up. */
    if (windowContent || dispatching) { [NSApp postEvent:event atStart:NO]; return; }
    SEL method=type==NSMouseMoved?@selector(mouseMoved:):type==NSMouseEntered?@selector(mouseEntered:):type==NSMouseExited?@selector(mouseExited:)
      :type==NSLeftMouseDown?@selector(mouseDown:):type==NSLeftMouseUp?@selector(mouseUp:):type==NSLeftMouseDragged?@selector(mouseDragged:)
      :type==NSRightMouseDown?@selector(rightMouseDown:):type==NSRightMouseUp?@selector(rightMouseUp:):type==NSRightMouseDragged?@selector(rightMouseDragged:)
      :type==NSOtherMouseDown?@selector(otherMouseDown:):type==NSOtherMouseUp?@selector(otherMouseUp:):@selector(otherMouseDragged:);
    // Leave GTK's event callback before invoking application code. A custom
    // mouseDown may enter an AppKit tracking/modal loop; GTK must remain pumpable.
    NSArray *request=@[event,NSStringFromSelector(method)];
    [pendingEvents addObject:request];
    [[NSRunLoop mainRunLoop] performSelector:@selector(deliver:) target:self
      argument:request order:0
      modes:@[NSDefaultRunLoopMode,NSRunLoopCommonModes,NSModalPanelRunLoopMode,NSEventTrackingRunLoopMode]];
  } @finally { [self release]; }
}
- (void)key:(guint)keyval code:(guint)code state:(GdkModifierType)state up:(BOOL)up
{
  gunichar ch=gdk_keyval_to_unicode(keyval);
  switch(keyval) {
    case GDK_KEY_Left: ch=NSLeftArrowFunctionKey; break; case GDK_KEY_Right: ch=NSRightArrowFunctionKey; break;
    case GDK_KEY_Up: ch=NSUpArrowFunctionKey; break; case GDK_KEY_Down: ch=NSDownArrowFunctionKey; break;
    case GDK_KEY_Return: ch='\r'; break; case GDK_KEY_BackSpace: ch=NSBackspaceCharacter; break;
    case GDK_KEY_Escape: ch=0x1b; break;
  }
  char utf8[8]={0}; g_unichar_to_utf8(ch,utf8);
  NSString *text=ch?[NSString stringWithUTF8String:utf8]:@"";
  NSEvent *event=[NSEvent keyEventWithType:up?NSKeyUp:NSKeyDown location:NSZeroPoint modifierFlags:modifiers(state)
    timestamp:g_get_monotonic_time()/1e6 windowNumber:source.window.windowNumber context:nil
    characters:text charactersIgnoringModifiers:text isARepeat:NO keyCode:code];
  if(windowContent) { [NSApp postEvent:event atStart:NO]; return; }
  NSArray *request=@[event,NSStringFromSelector(up?@selector(keyUp:):@selector(keyDown:))];
  [pendingEvents addObject:request];
  [[NSRunLoop mainRunLoop] performSelector:@selector(deliver:) target:self
    argument:request order:0
    modes:@[NSDefaultRunLoopMode,NSRunLoopCommonModes,NSModalPanelRunLoopMode,NSEventTrackingRunLoopMode]];
}
- (void)deliver:(NSArray *)request
{
  if ([pendingEvents indexOfObjectIdenticalTo:request]==NSNotFound) return;
  [pendingEvents removeObjectIdenticalTo:request];
  if (!source || (!windowContent && !GSNativeViewPeerForView(source))) return;
  NSEvent *event=request[0];
  if (windowContent || dispatching) { [NSApp postEvent:event atStart:NO]; return; }
  [self retain]; dispatching=YES;
  id<GSNativeEventSource> previous=GSSetNativeEventSource(self);
  @try { [source performSelector:NSSelectorFromString(request[1]) withObject:event]; }
  @finally { GSSetNativeEventSource(previous); dispatching=NO; [self release]; }
}
- (NSEvent *)nativeEventMatchingMask:(NSUInteger)mask dequeue:(BOOL)dequeue
{
  for (NSArray *request in pendingEvents) {
    NSEvent *event=request[0];
    if ((mask & (1UL<<event.type))!=0) {
      [[event retain] autorelease];
      if(dequeue) [pendingEvents removeObjectIdenticalTo:request];
      return event;
    }
  }
  return nil;
}
- (void)dealloc
{
  if(input) { gtk_im_context_set_client_widget(input,NULL); g_object_unref(input); }
  if(texture) g_object_unref(texture);
  [pendingEvents release]; [context release]; [bitmap release];
  if(!windowContent) [source release]; [super dealloc];
}
@end
