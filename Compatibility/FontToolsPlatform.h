#pragma once
// Apple SDK spellings used by GSFontTools; scoped to this application build.
#include <stdint.h>
#ifdef __OBJC__
#import <Cocoa/Cocoa.h>
#include <endian.h>
#define CFSwapInt16BigToHost be16toh
#define CFSwapInt16HostToBig htobe16
#define CFSwapInt32BigToHost be32toh
#define CFSwapInt32HostToBig htobe32
typedef uint8_t UInt8;
typedef int32_t Fixed;
#import <dispatch/dispatch.h>
#endif

#ifndef NS_TYPED_EXTENSIBLE_ENUM
#define NS_TYPED_EXTENSIBLE_ENUM
#endif
#ifndef __unused
#define __unused __attribute__((unused))
#endif
typedef uint8_t uint8;
#ifdef __cplusplus
#include <algorithm>
#endif
typedef uint16_t uint16;
typedef uint32_t uint32;
#define CFSwapInt64BigToHost be64toh
#define CFSwapInt64HostToBig htobe64
#ifdef __OBJC__
@interface NSString (GTK4FontToolsEncoding)
- (BOOL)getBytes:(void *)buffer maxLength:(NSUInteger)maxLength usedLength:(NSUInteger *)usedLength encoding:(NSStringEncoding)encoding options:(NSUInteger)options range:(NSRange)range remainingRange:(NSRange *)remainingRange;
@end
@interface NSObject (GTK4FontViewerDeclarations)
- (BOOL)tableView:(NSTableView *)view shouldShowCellExpansionForTableColumn:(NSTableColumn *)column row:(NSInteger)row;
@end
#endif

typedef uint32_t UInt32;
#define kTextEncodingMacRoman 0
#ifdef __OBJC__
#define CFStringRef NSString *
typedef NSData *CFDataRef;
typedef uint32_t CFStringEncoding;
#define CFBridgingRelease(value) (value)
static inline NSData *CFStringCreateExternalRepresentation(void *allocator, NSString *string, CFStringEncoding encoding, uint8_t lossByte) {
    if (encoding != 0) return nil;
    return [string dataUsingEncoding:NSMacOSRomanStringEncoding allowLossyConversion:YES];
}
static inline NSString *CFStringCreateFromExternalRepresentation(void *allocator, NSData *data, CFStringEncoding encoding) {
    if (encoding != 0) return nil;
    return [[NSString alloc] initWithData:data encoding:NSMacOSRomanStringEncoding];
}
#endif
