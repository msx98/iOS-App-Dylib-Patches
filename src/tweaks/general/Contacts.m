#import <Foundation/Foundation.h>
#import <Contacts/Contacts.h>
#import <objc/runtime.h>

#import "utils.h"

static NSArray *g_spoofedContacts = nil;

// Builds a CNMutableContact from a JSON dict.
// Expected JSON fields (all optional):
//   givenName, familyName, organizationName
//   phoneNumbers: [{ "label": "mobile", "value": "+1234567890" }]
//   emailAddresses: [{ "label": "work", "value": "foo@bar.com" }]
static CNMutableContact *buildContact(NSDictionary *dict) {
    CNMutableContact *contact = [[CNMutableContact alloc] init];

    contact.givenName        = dict[@"givenName"]       ?: @"";
    contact.familyName       = dict[@"familyName"]      ?: @"";
    contact.organizationName = dict[@"organizationName"]?: @"";

    NSArray *phones = dict[@"phoneNumbers"];
    if ([phones isKindOfClass:[NSArray class]]) {
        NSMutableArray *labeled = [NSMutableArray array];
        for (NSDictionary *p in phones) {
            NSString *value = p[@"value"];
            NSString *label = p[@"label"] ?: CNLabelPhoneNumberMobile;
            if (![value isKindOfClass:[NSString class]]) continue;
            [labeled addObject:[CNLabeledValue labeledValueWithLabel:label
                                                               value:[CNPhoneNumber phoneNumberWithStringValue:value]]];
        }
        contact.phoneNumbers = labeled;
    }

    NSArray *emails = dict[@"emailAddresses"];
    if ([emails isKindOfClass:[NSArray class]]) {
        NSMutableArray *labeled = [NSMutableArray array];
        for (NSDictionary *e in emails) {
            NSString *value = e[@"value"];
            NSString *label = e[@"label"] ?: CNLabelWork;
            if (![value isKindOfClass:[NSString class]]) continue;
            [labeled addObject:[CNLabeledValue labeledValueWithLabel:label value:value]];
        }
        contact.emailAddresses = labeled;
    }

    return contact;
}

// Mark a contact as spoofed so our isKeyAvailable hook can identify it.
static const void *kSpoofedContactKey = &kSpoofedContactKey;

static CNAuthorizationStatus hooked_authorizationStatus(id self, SEL _cmd, CNEntityType entityType) {
    return CNAuthorizationStatusAuthorized;
}

static void hooked_requestAccess(id self, SEL _cmd, CNEntityType entityType, void (^completionHandler)(BOOL granted, NSError *error)) {
    if (completionHandler) completionHandler(YES, nil);
}

static NSArray *hooked_unifiedContacts(id self, SEL _cmd, NSPredicate *predicate, NSArray *keys, NSError **error) {
    debug_print(@"[Contacts] hooked_unifiedContacts called, returning %lu contacts", (unsigned long)(g_spoofedContacts.count));
    if (error) *error = nil;
    return g_spoofedContacts ?: @[];
}

static void hooked_enumerateContacts(id self, SEL _cmd, id fetchRequest, NSError **error, void (^block)(id contact, BOOL *stop)) {
    NSArray *keysToFetch = [fetchRequest valueForKey:@"keysToFetch"];
    debug_print(@"[Contacts] hooked_enumerateContacts called, keys: %@", keysToFetch);
    if (error) *error = nil;
    for (id contact in g_spoofedContacts) {
        debug_print(@"[Contacts] passing contact: givenName=%@, familyName=%@, phones=%@",
            [contact valueForKey:@"givenName"],
            [contact valueForKey:@"familyName"],
            [contact valueForKey:@"phoneNumbers"]);
        BOOL stop = NO;
        block(contact, &stop);
        if (stop) break;
    }
}

static BOOL (*orig_isKeyAvailable)(id, SEL, id) = NULL;
static BOOL (*orig_areKeysAvailable)(id, SEL, NSArray *) = NULL;

static BOOL hooked_isKeyAvailable(id self, SEL _cmd, id key) {
    if (objc_getAssociatedObject(self, kSpoofedContactKey)) return YES;
    return orig_isKeyAvailable(self, _cmd, key);
}

static BOOL hooked_areKeysAvailable(id self, SEL _cmd, NSArray *keys) {
    if (objc_getAssociatedObject(self, kSpoofedContactKey)) return YES;
    return orig_areKeysAvailable(self, _cmd, keys);
}

static void spoofContactsFromJson() {
    Class cls = NSClassFromString(@"CNContactStore");
    if (!cls) {
        debug_print(@"[Contacts] CNContactStore not found");
        return;
    }
    Method fetchMethod = class_getInstanceMethod(cls, @selector(unifiedContactsMatchingPredicate:keysToFetch:error:));
    if (fetchMethod) {
        method_setImplementation(fetchMethod, (IMP)hooked_unifiedContacts);
        debug_print(@"[Contacts] Hooked unifiedContactsMatchingPredicate:keysToFetch:error:");
    } else {
        debug_print(@"[Contacts] WARN: unifiedContactsMatchingPredicate:keysToFetch:error: not found");
    }

    Method enumMethod = class_getInstanceMethod(cls, @selector(enumerateContactsWithFetchRequest:error:usingBlock:));
    if (enumMethod) {
        method_setImplementation(enumMethod, (IMP)hooked_enumerateContacts);
        debug_print(@"[Contacts] Hooked enumerateContactsWithFetchRequest:error:usingBlock:");
    } else {
        debug_print(@"[Contacts] WARN: enumerateContactsWithFetchRequest:error:usingBlock: not found");
    }

    // Hook isKeyAvailable: on CNContact so programmatically-built contacts
    // don't fail the "was this key fetched?" check the app may perform.
    Class contactCls = NSClassFromString(@"CNContact");
    if (contactCls) {
        Method isKeyMethod = class_getInstanceMethod(contactCls, @selector(isKeyAvailable:));
        if (isKeyMethod) {
            orig_isKeyAvailable = (BOOL(*)(id,SEL,id))method_getImplementation(isKeyMethod);
            method_setImplementation(isKeyMethod, (IMP)hooked_isKeyAvailable);
            debug_print(@"[Contacts] Hooked CNContact isKeyAvailable:");
        }
        Method areKeysMethod = class_getInstanceMethod(contactCls, @selector(areKeysAvailable:));
        if (areKeysMethod) {
            orig_areKeysAvailable = (BOOL(*)(id,SEL,NSArray*))method_getImplementation(areKeysMethod);
            method_setImplementation(areKeysMethod, (IMP)hooked_areKeysAvailable);
            debug_print(@"[Contacts] Hooked CNContact areKeysAvailable:");
        }
    }

    NSString *jsonPath = [getDocumentsPath() stringByAppendingPathComponent:@"TweakConfigs/Contacts/contacts.json"];
    if (![[NSFileManager defaultManager] fileExistsAtPath:jsonPath]) {
        debug_print(@"[Contacts] No contacts.json found at path: %@", jsonPath);
        return;
    }
    NSData *jsonData = [NSData dataWithContentsOfFile:jsonPath];
    if (!jsonData) {
        debug_print(@"[Contacts] Failed to read contacts.json at path: %@", jsonPath);
        return;
    }

    NSError *err = nil;
    NSDictionary *jsonDict = [NSJSONSerialization JSONObjectWithData:jsonData options:0 error:&err];
    if (![jsonDict isKindOfClass:[NSDictionary class]]) {
        debug_print(@"[Contacts] contacts.json parse error: %@", err);
        return;
    }
    NSArray *jsonArray = jsonDict[@"contacts"];
    if (![jsonArray isKindOfClass:[NSArray class]]) {
        debug_print(@"[Contacts] contacts.json missing 'contacts' array");
        return;
    }

    NSMutableArray *contacts = [NSMutableArray array];
    for (NSDictionary *dict in jsonArray) {
        CNMutableContact *contact = buildContact(dict);
        if (!contact) continue;
        objc_setAssociatedObject(contact, kSpoofedContactKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        [contacts addObject:contact];
    }
    g_spoofedContacts = [contacts copy];
    debug_print(@"[Contacts] Loaded %lu spoofed contacts from JSON", (unsigned long)g_spoofedContacts.count);
}

static void spoofContactsAuthorized() {
    debug_print(@"[Contacts] Spoofing contacts authorization to always granted");
    Class cls = NSClassFromString(@"CNContactStore");
    if (!cls) {
        debug_print(@"[Contacts] CNContactStore not found");
        return;
    }

    Method authMethod = class_getClassMethod(cls, @selector(authorizationStatusForEntityType:));
    if (authMethod) {
        method_setImplementation(authMethod, (IMP)hooked_authorizationStatus);
        debug_print(@"[Contacts] Hooked authorizationStatusForEntityType:");
    }

    Method reqMethod = class_getInstanceMethod(cls, @selector(requestAccessForEntityType:completionHandler:));
    if (reqMethod) {
        method_setImplementation(reqMethod, (IMP)hooked_requestAccess);
        debug_print(@"[Contacts] Hooked requestAccessForEntityType:completionHandler:");
    }
}

void init() {
    //spoofContactsFromJson();
    spoofContactsAuthorized();
}

