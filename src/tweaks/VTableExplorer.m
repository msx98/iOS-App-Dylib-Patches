#import <Foundation/Foundation.h>
#import <arpa/inet.h>
#import <dlfcn.h>
#import <libkern/OSByteOrder.h>
#import <netinet/in.h>
#import <os/log.h>
#import <sqlite3.h>
#import <sys/socket.h>
#import <unistd.h>

#import <objc/message.h>
#import <objc/runtime.h>

#import "utils.h"

void findInjectedSwiftClasses() {
    int numClasses = objc_getClassList(NULL, 0);
    Class *classes = (Class *)malloc(sizeof(Class) * numClasses);
    numClasses = objc_getClassList(classes, numClasses);

    for (int i = 0; i < numClasses; i++) {
        const char *name = class_getName(classes[i]);
        // Swift classes in ObjC look like "ModuleName.ClassName"
        if (strchr(name, '.')) {
            debug_print(@"Found Swift Class: %s\n", name);
        }
    }
    free(classes);
}

static void show_swift_vtable() {
    unsigned int count = 0;
    Class *classes = objc_copyClassList(&count);
    if (!classes) {
        debug_print(@"objc_copyClassList returned nil");
        return;
    }

    debug_print(@"Loaded classes:");
    for (unsigned int i = 0; i < count; i++) {
        const char *name = class_getName(classes[i]);
        debug_print(@"%s", name);
    }

    free(classes);
}

void init() {
    show_swift_vtable();
}

