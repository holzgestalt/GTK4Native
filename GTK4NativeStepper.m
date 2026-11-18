#import "GTK4NativeStepper.h"
#include <objc/runtime.h>
#include <math.h>

typedef struct {
  GtkWidget parent;
  GtkWidget *style, *up, *down, *separator;
  double minimum, maximum, increment, value, scale;
  gboolean wraps, autorepeat, disposed;
  int hovered, pressed;
  guint repeat, heldKey;
} GSNativeStepper;
typedef struct { GtkWidgetClass parent; } GSNativeStepperClass;
static void accessibleInit(GtkAccessibleRangeInterface *iface);
G_DEFINE_TYPE_WITH_CODE(GSNativeStepper, gs_native_stepper, GTK_TYPE_WIDGET,
  G_IMPLEMENT_INTERFACE(GTK_TYPE_ACCESSIBLE_RANGE,accessibleInit))
static guint changedSignal;

static void accessibleValue(GSNativeStepper *self)
{
  gtk_accessible_update_property(GTK_ACCESSIBLE(self),
    GTK_ACCESSIBLE_PROPERTY_VALUE_MIN,self->minimum,
    GTK_ACCESSIBLE_PROPERTY_VALUE_MAX,self->maximum,
    GTK_ACCESSIBLE_PROPERTY_VALUE_NOW,self->value,-1);
}
static void setValue(GSNativeStepper *self,double value)
{
  if(self->disposed || !gtk_widget_is_sensitive(GTK_WIDGET(self)) || !isfinite(value)) return;
  value=CLAMP(value,self->minimum,self->maximum);
  if(value==self->value) return;
  self->value=value;
  accessibleValue(self);
  // Actions can destroy/unparent the peer. Keep it alive through delivery.
  g_object_ref(self);
  g_signal_emit(self,changedSignal,0);
  g_object_unref(self);
}
void GTK4NativeStepperStep(GtkWidget *widget,int direction)
{
  GSNativeStepper *self=(GSNativeStepper *)widget;
  if(!GTK4NativeIsStepper(widget) || !direction) return;
  double value=self->value+self->increment*direction;
  if(self->wraps) {
    if(value>self->maximum) value=self->minimum;
    else if(value<self->minimum) value=self->maximum;
  }
  setValue(self,value);
}
static void stopRepeat(GSNativeStepper *self)
{
  if(self->repeat) { guint id=self->repeat; self->repeat=0; g_source_remove(id); }
}
static gboolean repeatStep(gpointer data)
{
  GSNativeStepper *self=g_object_ref(data);
  if(!self->disposed && self->pressed && self->hovered==self->pressed)
    GTK4NativeStepperStep(GTK_WIDGET(self),self->pressed);
  gboolean again=self->repeat && !self->disposed;
  g_object_unref(self);
  return again?G_SOURCE_CONTINUE:G_SOURCE_REMOVE;
}
static gboolean beginRepeat(gpointer data)
{
  GSNativeStepper *self=g_object_ref(data);
  self->repeat=0;
  if(!self->disposed && self->pressed && self->autorepeat) {
    self->repeat=g_timeout_add(75,repeatStep,self);
    repeatStep(self);
  }
  g_object_unref(self);
  return G_SOURCE_REMOVE;
}
static int halfAt(GtkWidget *widget,double x,double y)
{
  if(x<0 || y<0 || x>=gtk_widget_get_width(widget) || y>=gtk_widget_get_height(widget)) return 0;
  return y<gtk_widget_get_height(widget)/2.0?1:-1;
}
static void pressed(GtkGestureClick *gesture,int count,double x,double y,gpointer data)
{
  GSNativeStepper *self=g_object_ref(data);
  GtkWidget *widget=GTK_WIDGET(self);
  self->pressed=self->hovered=halfAt(widget,x,y);
  if(self->pressed && gtk_widget_is_sensitive(widget)) {
    gtk_gesture_set_state(GTK_GESTURE(gesture),GTK_EVENT_SEQUENCE_CLAIMED);
    gtk_widget_grab_focus(widget);
    if(self->autorepeat) self->repeat=g_timeout_add(450,beginRepeat,self);
    GTK4NativeStepperStep(widget,self->pressed);
    if(!self->disposed) gtk_widget_queue_draw(widget);
  }
  g_object_unref(self);
}
static void released(GtkGestureClick *gesture,int count,double x,double y,gpointer data)
{
  GSNativeStepper *self=data;
  stopRepeat(self); self->pressed=0; gtk_widget_queue_draw(GTK_WIDGET(self));
}
static void cancelled(GtkGesture *gesture,GdkEventSequence *sequence,gpointer data)
{ released(NULL,0,0,0,data); }
static void moved(GtkEventControllerMotion *controller,double x,double y,gpointer data)
{
  GSNativeStepper *self=data;
  int hovered=halfAt(GTK_WIDGET(self),x,y);
  if(hovered!=self->hovered) { self->hovered=hovered; gtk_widget_queue_draw(GTK_WIDGET(self)); }
}
static void left(GtkEventControllerMotion *controller,gpointer data)
{
  GSNativeStepper *self=data; self->hovered=0; gtk_widget_queue_draw(GTK_WIDGET(self));
}
static gboolean keyPressed(GtkEventControllerKey *controller,guint key,guint code,GdkModifierType state,gpointer data)
{
  GSNativeStepper *self=data;
  if(state&(GDK_CONTROL_MASK|GDK_ALT_MASK|GDK_SUPER_MASK|GDK_META_MASK)) return FALSE;
  int direction=(key==GDK_KEY_Up || key==GDK_KEY_KP_Up || key==GDK_KEY_plus || key==GDK_KEY_KP_Add)?1
    :(key==GDK_KEY_Down || key==GDK_KEY_KP_Down || key==GDK_KEY_minus || key==GDK_KEY_KP_Subtract)?-1:0;
  if(!direction && key!=GDK_KEY_Home && key!=GDK_KEY_End) return FALSE;
  if(!self->autorepeat && self->heldKey==key) return TRUE;
  self->heldKey=key;
  if(direction) GTK4NativeStepperStep(GTK_WIDGET(self),direction);
  else setValue(self,key==GDK_KEY_Home?self->minimum:self->maximum);
  return TRUE;
}
static void keyReleased(GtkEventControllerKey *controller,guint key,guint code,GdkModifierType state,gpointer data)
{ GSNativeStepper *self=data; if(self->heldKey==key) self->heldKey=0; }
static void focusLeft(GtkEventControllerFocus *controller,gpointer data)
{ ((GSNativeStepper *)data)->heldKey=0; }

static void measure(GtkWidget *widget,GtkOrientation orientation,int forSize,
  int *minimum,int *natural,int *minimumBaseline,int *naturalBaseline)
{
  GSNativeStepper *self=(GSNativeStepper *)widget;
  *minimum=orientation==GTK_ORIENTATION_HORIZONTAL?1:2;
  *natural=lround((orientation==GTK_ORIENTATION_HORIZONTAL?18:32)*self->scale);
  if(minimumBaseline) *minimumBaseline=-1;
  if(naturalBaseline) *naturalBaseline=-1;
}
static void allocate(GtkWidget *widget,int width,int height,int baseline)
{
  GSNativeStepper *self=(GSNativeStepper *)widget;
  int half=height/2;
  int icon=MAX(1,MIN(lround(10*self->scale),MIN(width-2,half-2)));
  gtk_image_set_pixel_size(GTK_IMAGE(self->up),icon);
  gtk_image_set_pixel_size(GTK_IMAGE(self->down),icon);
  GtkAllocation top={(width-icon)/2,(half-icon)/2,icon,icon};
  GtkAllocation bottom={(width-icon)/2,half+(height-half-icon)/2,icon,icon};
  GtkAllocation separator={1,half,MAX(1,width-2),1};
  gtk_widget_size_allocate(self->up,&top,-1);
  gtk_widget_size_allocate(self->down,&bottom,-1);
  gtk_widget_size_allocate(self->separator,&separator,-1);
}
static void snapshot(GtkWidget *widget,GtkSnapshot *snapshot)
{
  GSNativeStepper *self=(GSNativeStepper *)widget;
  float width=gtk_widget_get_width(widget),height=gtk_widget_get_height(widget);
  GtkStateFlags base=gtk_widget_get_state_flags(widget)&~(GTK_STATE_FLAG_PRELIGHT|GTK_STATE_FLAG_ACTIVE|GTK_STATE_FLAG_FOCUSED);
  // Use GTK's actual button background/border at the compact allocation. CSS
  // minimums and entry padding must not enlarge an existing NSStepper frame.
  for(int i=0;i<2;i++) {
    int direction=i==0?1:-1;
    GtkStateFlags state=base;
    if(gtk_widget_is_sensitive(widget) && self->hovered==direction) {
      state|=GTK_STATE_FLAG_PRELIGHT;
      if(self->pressed==direction) state|=GTK_STATE_FLAG_ACTIVE;
    }
    gtk_widget_set_state_flags(self->style,state,TRUE);
    GtkStyleContext *style=gtk_widget_get_style_context(self->style);
    graphene_rect_t clip=GRAPHENE_RECT_INIT(0,i==0?0:height/2,width,height/2);
    gtk_snapshot_push_clip(snapshot,&clip);
    gtk_snapshot_render_background(snapshot,style,0,0,width,height);
    gtk_snapshot_render_frame(snapshot,style,0,0,width,height);
    gtk_snapshot_pop(snapshot);
  }
  gtk_widget_snapshot_child(widget,self->separator,snapshot);
  gtk_widget_snapshot_child(widget,self->up,snapshot);
  gtk_widget_snapshot_child(widget,self->down,snapshot);
  if(gtk_widget_has_visible_focus(widget))
    gtk_snapshot_render_focus(snapshot,gtk_widget_get_style_context(self->style),0,0,width,height);
}
static void stateChanged(GtkWidget *widget,GtkStateFlags previous)
{
  GSNativeStepper *self=(GSNativeStepper *)widget;
  if(!gtk_widget_is_sensitive(widget)) { stopRepeat(self); self->pressed=0; self->heldKey=0; }
  GTK_WIDGET_CLASS(gs_native_stepper_parent_class)->state_flags_changed(widget,previous);
  gtk_widget_queue_draw(widget);
}
static void unmap(GtkWidget *widget)
{
  GSNativeStepper *self=(GSNativeStepper *)widget;
  stopRepeat(self); self->pressed=0; self->heldKey=0;
  GTK_WIDGET_CLASS(gs_native_stepper_parent_class)->unmap(widget);
}
static void dispose(GObject *object)
{
  GSNativeStepper *self=(GSNativeStepper *)object;
  self->disposed=TRUE; stopRepeat(self);
  GtkWidget *child;
  while((child=gtk_widget_get_first_child(GTK_WIDGET(self)))) gtk_widget_unparent(child);
  g_clear_object(&self->style);
  G_OBJECT_CLASS(gs_native_stepper_parent_class)->dispose(object);
}
static gboolean accessibleSet(GtkAccessibleRange *range,double value)
{
  GSNativeStepper *self=(GSNativeStepper *)range;
  if(!gtk_widget_is_sensitive(GTK_WIDGET(self)) || !isfinite(value)) return FALSE;
  setValue(self,value); return TRUE;
}
static void accessibleInit(GtkAccessibleRangeInterface *iface) { iface->set_current_value=accessibleSet; }
static void gs_native_stepper_class_init(GSNativeStepperClass *cls)
{
  G_OBJECT_CLASS(cls)->dispose=dispose;
  GtkWidgetClass *widget=GTK_WIDGET_CLASS(cls);
  widget->measure=measure; widget->size_allocate=allocate; widget->snapshot=snapshot;
  widget->state_flags_changed=stateChanged; widget->unmap=unmap;
  gtk_widget_class_set_css_name(widget,"stepper");
  gtk_widget_class_set_accessible_role(widget,GTK_ACCESSIBLE_ROLE_SPIN_BUTTON);
  changedSignal=g_signal_new("value-changed",G_TYPE_FROM_CLASS(cls),G_SIGNAL_RUN_LAST,0,NULL,NULL,NULL,G_TYPE_NONE,0);
}
static void gs_native_stepper_init(GSNativeStepper *self)
{
  self->scale=1; self->maximum=100; self->increment=1; self->autorepeat=TRUE;
  self->style=gtk_button_new(); g_object_ref_sink(self->style);
  self->up=gtk_image_new_from_icon_name("pan-up-symbolic");
  self->down=gtk_image_new_from_icon_name("pan-down-symbolic");
  self->separator=gtk_separator_new(GTK_ORIENTATION_HORIZONTAL);
  GtkWidget *children[]={self->up,self->down,self->separator};
  for(int i=0;i<3;i++) { gtk_widget_set_can_target(children[i],FALSE); gtk_widget_set_parent(children[i],GTK_WIDGET(self)); }
  gtk_widget_set_focusable(GTK_WIDGET(self),TRUE);
  gtk_widget_set_overflow(GTK_WIDGET(self),GTK_OVERFLOW_HIDDEN);
  GtkGesture *click=gtk_gesture_click_new(); gtk_gesture_single_set_button(GTK_GESTURE_SINGLE(click),1);
  g_signal_connect(click,"pressed",G_CALLBACK(pressed),self);
  g_signal_connect(click,"released",G_CALLBACK(released),self);
  g_signal_connect(click,"cancel",G_CALLBACK(cancelled),self);
  gtk_widget_add_controller(GTK_WIDGET(self),GTK_EVENT_CONTROLLER(click));
  GtkEventController *motion=gtk_event_controller_motion_new();
  g_signal_connect(motion,"enter",G_CALLBACK(moved),self); g_signal_connect(motion,"motion",G_CALLBACK(moved),self);
  g_signal_connect(motion,"leave",G_CALLBACK(left),self); gtk_widget_add_controller(GTK_WIDGET(self),motion);
  GtkEventController *keys=gtk_event_controller_key_new();
  g_signal_connect(keys,"key-pressed",G_CALLBACK(keyPressed),self); g_signal_connect(keys,"key-released",G_CALLBACK(keyReleased),self);
  gtk_widget_add_controller(GTK_WIDGET(self),keys);
  GtkEventController *focus=gtk_event_controller_focus_new();
  g_signal_connect(focus,"leave",G_CALLBACK(focusLeft),self); gtk_widget_add_controller(GTK_WIDGET(self),focus);
}
GtkWidget *GTK4NativeStepperNew(double scale)
{
  GSNativeStepper *self=g_object_new(gs_native_stepper_get_type(),NULL); self->scale=scale;
  return GTK_WIDGET(self);
}
gboolean GTK4NativeIsStepper(GtkWidget *widget)
{ return widget && G_TYPE_CHECK_INSTANCE_TYPE(widget,gs_native_stepper_get_type()); }
void GTK4NativeStepperConfigure(GtkWidget *widget,double minimum,double maximum,double increment,double value,gboolean wraps,gboolean autorepeat)
{
  GSNativeStepper *self=(GSNativeStepper *)widget;
  self->minimum=minimum; self->maximum=MAX(minimum,maximum); self->increment=increment;
  self->value=CLAMP(value,self->minimum,self->maximum); self->wraps=wraps; self->autorepeat=autorepeat;
  if(!autorepeat) stopRepeat(self);
  accessibleValue(self);
}
double GTK4NativeStepperGetValue(GtkWidget *widget) { return ((GSNativeStepper *)widget)->value; }

static char presentationKey;
@implementation NSStepper (GTK4NativePresentation)
- (BOOL)gtk4NativeUsesSpinButton { return [objc_getAssociatedObject(self,&presentationKey) boolValue]; }
- (void)setGtk4NativeUsesSpinButton:(BOOL)enabled
{
  objc_setAssociatedObject(self,&presentationKey,@(enabled),OBJC_ASSOCIATION_RETAIN_NONATOMIC);
  [self setNeedsDisplay:YES];
}
@end
