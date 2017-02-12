//
//  Copyright © 2015 Catamorphic Co. All rights reserved.
//

#import "DarklyXCTestCase.h"
#import "LDDataManager.h"
#import "DarklyConstants.h"
#import <OHPathHelpers.h>
#import <OCMock.h>

@implementation DarklyXCTestCase

- (void)setUp {
    [super setUp];

    [[NSUserDefaults standardUserDefaults] removeObjectForKey:kUserDictionaryStorageKey];
    [[LDDataManager sharedManager] flushEventsDictionary];
}

- (void)tearDown {
    [super tearDown];
}

-(void) deleteAllEvents {
}
@end