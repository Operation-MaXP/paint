#import <Cocoa/Cocoa.h>
#import "AppDelegate.h" // Ensure this matches the filename of your AppDelegate header

int main(int argc, const char * argv[]) {
    @autoreleasepool {
        // Create the shared NSApplication instance. This needs to be done first.
        NSApplication *application = [NSApplication sharedApplication];

        // Create an instance of your AppDelegate.
        // This object will handle application lifecycle events.
        AppDelegate *appDelegate = [[AppDelegate alloc] init];

        // Set your AppDelegate instance as the delegate for the NSApplication.
        [application setDelegate:appDelegate];

        // Start the main event loop for the application.
        // This call will not return until the application is terminated.
        // It handles event processing, window updates, etc.
        [application run];
    }
    // When [application run] returns, the application is exiting.
    return EXIT_SUCCESS;
}
