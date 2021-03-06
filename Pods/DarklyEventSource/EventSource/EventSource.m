//
//  EventSource.m
//  EventSource
//
//  Created by Neil on 25/07/2013.
//  Copyright (c) 2013 Neil Cowburn. All rights reserved.
//

#import "EventSource.h"
#import <CoreGraphics/CGBase.h>

static CGFloat const ES_RETRY_INTERVAL = 1.0;
static CGFloat const ES_DEFAULT_TIMEOUT = 300.0;

static NSString *const ESKeyValueDelimiter = @":";
static NSString *const ESEventSeparatorLFLF = @"\n\n";
static NSString *const ESEventSeparatorCRCR = @"\r\r";
static NSString *const ESEventSeparatorCRLFCRLF = @"\r\n\r\n";
static NSString *const ESEventKeyValuePairSeparator = @"\n";

static NSString *const ESEventDataKey = @"data";
static NSString *const ESEventIDKey = @"id";
static NSString *const ESEventEventKey = @"event";
static NSString *const ESEventRetryKey = @"retry";

@interface EventSource () <NSURLConnectionDelegate, NSURLConnectionDataDelegate> {
    BOOL wasClosed;
    dispatch_queue_t messageQueue;
    dispatch_queue_t connectionQueue;
}

@property (nonatomic, strong) NSURL *eventURL;
@property (nonatomic, strong) NSURLConnection *eventSource;
@property (nonatomic, strong) NSMutableDictionary *listeners;
@property (nonatomic, assign) NSTimeInterval timeoutInterval;
@property (nonatomic, assign) NSTimeInterval retryInterval;
@property (nonatomic, strong) NSString *mobileKey;
@property (nonatomic, strong) id lastEventID;

- (void)_open;
- (void)_dispatchEvent:(Event *)e;

@end

@implementation EventSource

+ (instancetype)eventSourceWithURL:(NSURL *)URL mobileKey:(NSString *)mobileKey
{
    return [[EventSource alloc] initWithURL:URL mobileKey:mobileKey];
}

+ (instancetype)eventSourceWithURL:(NSURL *)URL mobileKey:(NSString *)mobileKey timeoutInterval:(NSTimeInterval)timeoutInterval
{
    return [[EventSource alloc] initWithURL:URL mobileKey:mobileKey timeoutInterval:timeoutInterval];
}

- (instancetype)initWithURL:(NSURL *)URL mobileKey:(NSString *)mobileKey
{
    return [self initWithURL:URL mobileKey:mobileKey timeoutInterval:ES_DEFAULT_TIMEOUT];
}

- (instancetype)initWithURL:(NSURL *)URL mobileKey:(NSString *)mobileKey timeoutInterval:(NSTimeInterval)timeoutInterval
{
    self = [super init];
    if (self) {
        _listeners = [NSMutableDictionary dictionary];
        _eventURL = URL;
        _timeoutInterval = timeoutInterval;
        _retryInterval = ES_RETRY_INTERVAL;
        _mobileKey = mobileKey;
        messageQueue = dispatch_queue_create("co.cwbrn.eventsource-queue", DISPATCH_QUEUE_SERIAL);
        connectionQueue = dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_HIGH, 0);

        dispatch_time_t popTime = dispatch_time(DISPATCH_TIME_NOW, (int64_t)(_retryInterval * NSEC_PER_SEC));
        dispatch_after(popTime, connectionQueue, ^(void){
            [self _open];
        });
    }
    return self;
}

- (void)addEventListener:(NSString *)eventName handler:(EventSourceEventHandler)handler
{
    if (self.listeners[eventName] == nil) {
        [self.listeners setObject:[NSMutableArray array] forKey:eventName];
    }
    
    [self.listeners[eventName] addObject:handler];
}

- (void)onMessage:(EventSourceEventHandler)handler
{
    [self addEventListener:MessageEvent handler:handler];
}

- (void)onError:(EventSourceEventHandler)handler
{
    [self addEventListener:ErrorEvent handler:handler];
}

- (void)onOpen:(EventSourceEventHandler)handler
{
    [self addEventListener:OpenEvent handler:handler];
}

- (void)onReadyStateChanged:(EventSourceEventHandler)handler
{
    [self addEventListener:ReadyStateEvent handler:handler];
}

- (void)close
{
    wasClosed = YES;
    [self.eventSource cancel];
}

// ---------------------------------------------------------------------------------------------------------------------

- (void)connection:(NSURLConnection *)connection didReceiveResponse:(NSURLResponse *)response
{
    NSHTTPURLResponse *httpResponse = (NSHTTPURLResponse *)response;
    if (httpResponse.statusCode == 200) {
        // Opened
        Event *e = [Event new];
        e.readyState = kEventStateOpen;
        

        [self _dispatchEvent:e type:ReadyStateEvent];
        [self _dispatchEvent:e type:OpenEvent];
    }
}

- (void)connection:(NSURLConnection *)connection didFailWithError:(NSError *)error
{
    self.eventSource = nil;

    if (wasClosed) {
        return;
    }

    Event *e = [Event new];
    e.readyState = kEventStateClosed;
    e.error = error;

    [self _dispatchEvent:e type:ReadyStateEvent];
    [self _dispatchEvent:e type:ErrorEvent];

    dispatch_time_t popTime = dispatch_time(DISPATCH_TIME_NOW, (int64_t)(_retryInterval * NSEC_PER_SEC));
    dispatch_after(popTime, connectionQueue, ^(void){
        [self _open];
    });
}

- (void)connection:(NSURLConnection *)connection didReceiveData:(NSData *)data
{
    NSString *eventString = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
    NSArray *lines = [eventString componentsSeparatedByCharactersInSet:[NSCharacterSet newlineCharacterSet]];

    Event *event = [Event new];
    event.readyState = kEventStateOpen;

    for (NSString *line in lines) {
        if ([line hasPrefix:ESKeyValueDelimiter]) {
            continue;
        }

        if (!line || line.length == 0) {
                dispatch_async(messageQueue, ^{
                    [self _dispatchEvent:event];
                });
                
                event = [Event new];
                event.readyState = kEventStateOpen;
            continue;
        }

        @autoreleasepool {
            NSScanner *scanner = [NSScanner scannerWithString:line];
            scanner.charactersToBeSkipped = [NSCharacterSet whitespaceCharacterSet];

            NSString *key, *value;
            [scanner scanUpToString:ESKeyValueDelimiter intoString:&key];
            [scanner scanString:ESKeyValueDelimiter intoString:nil];
            [scanner scanUpToCharactersFromSet:[NSCharacterSet newlineCharacterSet] intoString:&value];

            if (key && value) {
                if ([key isEqualToString:ESEventEventKey]) {
                    event.event = value;
                } else if ([key isEqualToString:ESEventDataKey]) {
                    if (event.data != nil) {
                        event.data = [event.data stringByAppendingFormat:@"\n%@", value];
                    } else {
                        event.data = value;
                    }
                } else if ([key isEqualToString:ESEventIDKey]) {
                    event.id = value;
                    self.lastEventID = event.id;
                } else if ([key isEqualToString:ESEventRetryKey]) {
                    self.retryInterval = [value doubleValue];
                }
            }
        }
    }
}

- (void)connectionDidFinishLoading:(NSURLConnection *)connection
{
    self.eventSource = nil;

    if (wasClosed) {
        return;
    }
    
    Event *e = [Event new];
    e.readyState = kEventStateClosed;
    e.error = [NSError errorWithDomain:@""
                                  code:e.readyState
                              userInfo:@{ NSLocalizedDescriptionKey: @"Connection with the event source was closed." }];

    [self _dispatchEvent:e type:ReadyStateEvent];
    [self _dispatchEvent:e type:ErrorEvent];

    dispatch_time_t popTime = dispatch_time(DISPATCH_TIME_NOW, (int64_t)(_retryInterval * NSEC_PER_SEC));
    dispatch_after(popTime, connectionQueue, ^(void){
        [self _open];
    });
}

- (void)_open
{
    wasClosed = NO;
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:self.eventURL cachePolicy:NSURLRequestReloadIgnoringCacheData timeoutInterval:self.timeoutInterval];
    [request addValue:[NSString stringWithFormat:@"api_key %@",self.mobileKey] forHTTPHeaderField:@"Authorization"];
    if (self.lastEventID) {
        [request setValue:self.lastEventID forHTTPHeaderField:@"Last-Event-ID"];
    }
    self.eventSource = [[NSURLConnection alloc] initWithRequest:request delegate:self startImmediately:YES];

    Event *e = [Event new];
    e.readyState = kEventStateConnecting;

    [self _dispatchEvent:e type:ReadyStateEvent];

    if (![NSThread isMainThread]) {
        CFRunLoopRun();
    }
}

- (void)_dispatchEvent:(Event *)event type:(NSString * const)type
{
    NSArray *errorHandlers = self.listeners[type];
    for (EventSourceEventHandler handler in errorHandlers) {
        dispatch_async(connectionQueue, ^{
            handler(event);
        });
    }
}

- (void)_dispatchEvent:(Event *)event
{
    [self _dispatchEvent:event type:MessageEvent];

    if (event.event != nil) {
        [self _dispatchEvent:event type:event.event];
    }
}

@end

// ---------------------------------------------------------------------------------------------------------------------

@implementation Event

- (NSString *)description
{
    NSString *state = nil;
    switch (self.readyState) {
        case kEventStateConnecting:
            state = @"CONNECTING";
            break;
        case kEventStateOpen:
            state = @"OPEN";
            break;
        case kEventStateClosed:
            state = @"CLOSED";
            break;
    }
    
    return [NSString stringWithFormat:@"<%@: readyState: %@, id: %@; event: %@; data: %@>",
            [self class],
            state,
            self.id,
            self.event,
            self.data];
}

@end

NSString *const MessageEvent = @"message";
NSString *const ErrorEvent = @"error";
NSString *const OpenEvent = @"open";
NSString *const ReadyStateEvent = @"readyState";
