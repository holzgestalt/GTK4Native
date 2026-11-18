#import "FontToolsPlatform.h"

@implementation NSString (GTK4FontToolsEncoding)
- (BOOL)getBytes:(void *)buffer maxLength:(NSUInteger)maxLength usedLength:(NSUInteger *)usedLength encoding:(NSStringEncoding)encoding options:(NSUInteger)options range:(NSRange)range remainingRange:(NSRange *)remainingRange
{
    NSRange consumed = range;
    NSData *data = [[self substringWithRange:consumed] dataUsingEncoding:encoding allowLossyConversion:(options & 1) != 0];
    while (consumed.length && data.length > maxLength) {
        NSRange last = [self rangeOfComposedCharacterSequenceAtIndex:NSMaxRange(consumed) - 1];
        consumed.length = last.location - range.location;
        data = [[self substringWithRange:consumed] dataUsingEncoding:encoding allowLossyConversion:(options & 1) != 0];
    }
    if (!data) {
        if (usedLength) *usedLength = 0;
        if (remainingRange) *remainingRange = range;
        return NO;
    }
    if (buffer) memcpy(buffer, data.bytes, data.length);
    if (usedLength) *usedLength = data.length;
    if (remainingRange) *remainingRange = NSMakeRange(NSMaxRange(consumed), NSMaxRange(range) - NSMaxRange(consumed));
    return consumed.length > 0 || range.length == 0;
}
@end

#import "WebKit/WebKit.h"
#import "../GTK4NativeView.h"
@interface WKWebView () <GTK4NativeCustomView>
- (void)openSpecification:(id)sender;
@end
static void openBrowser(GtkButton *button, gpointer data) {
    [(__bridge WKWebView *)data openSpecification:nil];
}
static void releaseBrowser(gpointer data) { id owner = (__bridge_transfer id)data; (void)owner; }
@implementation WKWebView {
    GtkWidget *_openButton;
    NSURL *_requestURL;
}
- (GtkWidget *)gtk4NativeWidget {
    if (_openButton) g_object_remove_weak_pointer(G_OBJECT(_openButton),(gpointer *)&_openButton);
    GtkWidget *box = gtk_box_new(GTK_ORIENTATION_VERTICAL,0);
    _openButton = gtk_button_new_with_label("Open specification in browser");
    g_object_add_weak_pointer(G_OBJECT(_openButton),(gpointer *)&_openButton);
    gtk_widget_set_halign(_openButton,GTK_ALIGN_START);
    gtk_widget_set_valign(_openButton,GTK_ALIGN_START);
    gtk_widget_set_margin_start(_openButton,12);
    gtk_widget_set_margin_top(_openButton,12);
    gtk_widget_set_margin_end(_openButton,12);
    gtk_widget_set_margin_bottom(_openButton,12);
    gtk_widget_set_sensitive(_openButton,[_requestURL.scheme isEqualToString:@"https"]);
    g_object_set_data_full(G_OBJECT(box),"appkit-specification-owner",(__bridge_retained void *)self,releaseBrowser);
    g_signal_connect(_openButton,"clicked",G_CALLBACK(openBrowser),(__bridge void *)self);
    gtk_box_append(GTK_BOX(box),_openButton);
    return box;
}
- (void)loadRequest:(NSURLRequest *)request {
    _requestURL = request.URL;
    if (_openButton) gtk_widget_set_sensitive(_openButton,[_requestURL.scheme isEqualToString:@"https"]);
}
- (void)openSpecification:(id)sender {
    if ([_requestURL.scheme isEqualToString:@"https"]) [[NSWorkspace sharedWorkspace] openURL:_requestURL];
}
- (void)dealloc {
    if (_openButton) g_object_remove_weak_pointer(G_OBJECT(_openButton),(gpointer *)&_openButton);
}
@end
