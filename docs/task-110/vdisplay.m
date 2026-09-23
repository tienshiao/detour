// Temporary 2x virtual display for website captures (TASK-110). Lives until killed.
#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>

@interface CGVirtualDisplayDescriptor : NSObject
@property(retain, nonatomic) dispatch_queue_t queue;
@property(retain, nonatomic) NSString *name;
@property(nonatomic) unsigned int maxPixelsHigh;
@property(nonatomic) unsigned int maxPixelsWide;
@property(nonatomic) CGSize sizeInMillimeters;
@property(nonatomic) unsigned int serialNum;
@property(nonatomic) unsigned int productID;
@property(nonatomic) unsigned int vendorID;
@property(copy, nonatomic) void (^terminationHandler)(id, id);
@end
@interface CGVirtualDisplayMode : NSObject
- (instancetype)initWithWidth:(unsigned int)width height:(unsigned int)height refreshRate:(double)refreshRate;
@end
@interface CGVirtualDisplaySettings : NSObject
@property(retain, nonatomic) NSArray *modes;
@property(nonatomic) unsigned int hiDPI;
@end
@interface CGVirtualDisplay : NSObject
- (instancetype)initWithDescriptor:(CGVirtualDisplayDescriptor *)descriptor;
- (BOOL)applySettings:(CGVirtualDisplaySettings *)settings;
@property(readonly, nonatomic) unsigned int displayID;
@end

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        unsigned int w = 1600, h = 1000;  // points; pixels are 2x
        CGVirtualDisplayDescriptor *d = [CGVirtualDisplayDescriptor new];
        d.queue = dispatch_get_main_queue();
        d.name = @"Detour Capture 2x";
        d.maxPixelsWide = w * 2;
        d.maxPixelsHigh = h * 2;
        d.sizeInMillimeters = CGSizeMake(340, 212);
        d.serialNum = 0x0D70;
        d.productID = 0x1234;
        d.vendorID = 0x3456;
        d.terminationHandler = ^(id a, id b) { NSLog(@"virtual display terminated"); };
        CGVirtualDisplay *display = [[CGVirtualDisplay alloc] initWithDescriptor:d];
        if (!display) { fprintf(stderr, "create failed\n"); return 1; }
        CGVirtualDisplaySettings *s = [CGVirtualDisplaySettings new];
        s.hiDPI = 1;
        s.modes = @[[[CGVirtualDisplayMode alloc] initWithWidth:w height:h refreshRate:60]];
        if (![display applySettings:s]) { fprintf(stderr, "applySettings failed\n"); return 1; }
        printf("displayID=%u\n", display.displayID);
        fflush(stdout);
        [[NSRunLoop mainRunLoop] run];
    }
    return 0;
}
