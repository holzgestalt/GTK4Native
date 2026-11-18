#import <AppKit/NSStepper.h>
#include <gtk/gtk.h>

/* Compact, editor-free GTK peer. Drawing, input and repeat live in GTK. */
GtkWidget *GTK4NativeStepperNew(double scale);
gboolean GTK4NativeIsStepper(GtkWidget *widget);
void GTK4NativeStepperConfigure(GtkWidget *widget, double minimum, double maximum,
  double increment, double value, gboolean wraps, gboolean autorepeat);
double GTK4NativeStepperGetValue(GtkWidget *widget);
void GTK4NativeStepperStep(GtkWidget *widget, int direction);

/* Optional provider-side full GtkSpinButton presentation. The theme must
   provide enough width for its numeric editor. Applications need no GTK API. */
@interface NSStepper (GTK4NativePresentation)
- (BOOL)gtk4NativeUsesSpinButton;
- (void)setGtk4NativeUsesSpinButton:(BOOL)enabled;
@end
