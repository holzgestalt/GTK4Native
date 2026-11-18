#pragma once
#import <AppKit/AppKit.h>
// The Linux SDK has no Apple WebKit. Offer an explicit system-browser link.
@interface WKWebView : NSView
- (void)loadRequest:(NSURLRequest *)request;
@end
