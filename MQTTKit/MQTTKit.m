//
//  MQTTKit.m
//  MQTTKit
//
//  Created by Jeff Mesnil on 22/10/2013.
//  Copyright (c) 2013 Jeff Mesnil. All rights reserved.
//  Copyright 2012 Nicholas Humfrey. All rights reserved.
//

#import "MQTTKit.h"
#import "mosquitto.h"

#if 0 // set to 1 to enable logs

#define LogDebug(frmt, ...) NSLog(frmt, ##__VA_ARGS__);

#else

#define LogDebug(frmt, ...) {}

#endif

/* 
 Log types
 
 MOSQ_LOG_NONE 0x00
 MOSQ_LOG_INFO 0x01
 MOSQ_LOG_NOTICE 0x02
 MOSQ_LOG_WARNING 0x04
 MOSQ_LOG_ERR 0x08
 MOSQ_LOG_DEBUG 0x10
 MOSQ_LOG_SUBSCRIBE 0x20
 MOSQ_LOG_UNSUBSCRIBE 0x40
 MOSQ_LOG_WEBSOCKETS 0x80
 MOSQ_LOG_ALL 0xFFFF
 
 */

#define MOSQ_LOG_LEVEL 0x01 || 0x02

#ifdef WITH_TLS

NSString *const MQTTKitTLSVersion1 = @"tlsv1";
NSString *const MQTTKitTLSVersion1_1 = @"tlsv1.1";
NSString *const MQTTKitTLSVersion1_2 = @"tlsv1.2";

#endif

#pragma mark - MQTT Message

@interface MQTTMessage()

@property (readwrite, assign) unsigned short mid;
@property (readwrite, copy) NSString *topic;
@property (readwrite, copy) NSData *payload;
@property (readwrite, assign) MQTTQualityOfService qos;
@property (readwrite, assign) BOOL retained;

@end

@implementation MQTTMessage

-(id)initWithTopic:(NSString *)topic
           payload:(NSData *)payload
               qos:(MQTTQualityOfService)qos
            retain:(BOOL)retained
               mid:(short)mid{
    if ((self = [super init])) {
        self.topic = topic;
        self.payload = payload;
        self.qos = qos;
        self.retained = retained;
        self.mid = mid;
    }
    return self;
}

- (NSString *)payloadString {
    return [[NSString alloc] initWithBytes:self.payload.bytes length:self.payload.length encoding:NSUTF8StringEncoding];
}

@end

#pragma mark - MQTT Client

@interface MQTTClient()

@property (nonatomic, copy) void (^connectionCompletionHandler)(NSUInteger code);
@property (nonatomic, strong) NSMutableDictionary *subscriptionHandlers;
@property (nonatomic, strong) NSMutableDictionary *unsubscriptionHandlers;
// dictionary of mid -> completion handlers for messages published with a QoS of 1 or 2
@property (nonatomic, strong) NSMutableDictionary *publishHandlers;
@property (nonatomic, assign) BOOL connected;

// dispatch queue to run the mosquitto_loop_forever.
@property (nonatomic, strong) dispatch_queue_t queue;

@end

@implementation MQTTClient



#pragma mark - mosquitto callback methods

static void on_connect(struct mosquitto *mosq, void *obj, int rc){
    MQTTClient* client = (__bridge MQTTClient*)obj;
    LogDebug(@"[%@] on_connect rc = %d", client.clientID, rc);
    client.connected = (rc == ConnectionAccepted);
    if (client.connectionCompletionHandler) {
        client.connectionCompletionHandler(rc);
    }
}

static void on_disconnect(struct mosquitto *mosq, void *obj, int rc){
    MQTTClient* client = (__bridge MQTTClient*)obj;
    LogDebug(@"[%@] on_disconnect rc = %d", client.clientID, rc);
    [client.publishHandlers removeAllObjects];
    [client.subscriptionHandlers removeAllObjects];
    [client.unsubscriptionHandlers removeAllObjects];

    client.connected = NO;
    if (client.disconnectionHandler) {
        client.disconnectionHandler(rc);
    }
}

static void on_publish(struct mosquitto *mosq, void *obj, int message_id){
    MQTTClient* client = (__bridge MQTTClient*)obj;
    NSNumber *mid = [NSNumber numberWithInt:message_id];
    void (^handler)(int) = [client.publishHandlers objectForKey:mid];
    if (handler) {
        handler(message_id);
        if (message_id > 0) {
            [client.publishHandlers removeObjectForKey:mid];
        }
    }
}

static void on_message(struct mosquitto *mosq, void *obj, const struct mosquitto_message *mosq_msg){
    // Ensure these objects are cleaned up quickly by an autorelease pool.
    // The GCD autorelease pool isn't guaranteed to clean this up in any amount of time.
    // Source: https://developer.apple.com/library/ios/DOCUMENTATION/General/Conceptual/ConcurrencyProgrammingGuide/OperationQueues/OperationQueues.html#//apple_ref/doc/uid/TP40008091-CH102-SW1
    @autoreleasepool {
        NSString *topic = [NSString stringWithUTF8String: mosq_msg->topic];
        NSData *payload = [NSData dataWithBytes:mosq_msg->payload length:mosq_msg->payloadlen];
        MQTTMessage *message = [[MQTTMessage alloc] initWithTopic:topic
                                                          payload:payload
                                                              qos:mosq_msg->qos
                                                           retain:mosq_msg->retain
                                                              mid:mosq_msg->mid];
        MQTTClient* client = (__bridge MQTTClient*)obj;
        LogDebug(@"[%@] on message %@", client.clientID, message);
        if (client.messageHandler) {
            client.messageHandler(message);
        }
    }
}

static void on_subscribe(struct mosquitto *mosq, void *obj, int message_id, int qos_count, const int *granted_qos){
    MQTTClient* client = (__bridge MQTTClient*)obj;
    NSNumber *mid = [NSNumber numberWithInt:message_id];
    MQTTSubscriptionCompletionHandler handler = [client.subscriptionHandlers objectForKey:mid];
    if (handler) {
        NSMutableArray *grantedQos = [NSMutableArray arrayWithCapacity:qos_count];
        for (int i = 0; i < qos_count; i++) {
            [grantedQos addObject:[NSNumber numberWithInt:granted_qos[i]]];
        }
        handler(grantedQos);
        [client.subscriptionHandlers removeObjectForKey:mid];
    }
}

static void on_unsubscribe(struct mosquitto *mosq, void *obj, int message_id){
    MQTTClient* client = (__bridge MQTTClient*)obj;
    NSNumber *mid = [NSNumber numberWithInt:message_id];
    void (^completionHandler)(void) = [client.unsubscriptionHandlers objectForKey:mid];
    if (completionHandler) {
        completionHandler();
        [client.subscriptionHandlers removeObjectForKey:mid];
    }
}

static void on_log(struct mosquitto *mosq, void *userdata, int level, const char *str){
    int rc = level & MOSQ_LOG_LEVEL;
    if (rc){
        LogDebug(@"%@",[NSString stringWithUTF8String:str]);
    }
}

// Initialize is called just before the first object is allocated
+ (void)initialize {
    mosquitto_lib_init();
}

+ (NSString*)version {
    int major, minor, revision;
    mosquitto_lib_version(&major, &minor, &revision);
    return [NSString stringWithFormat:@"%d.%d.%d", major, minor, revision];
}

- (MQTTClient*) initWithClientId: (NSString*) clientId{
    return [self initWithClientId:clientId cleanSession:YES];
}

- (MQTTClient*) initWithClientId: (NSString *)clientId
                    cleanSession: (BOOL )cleanSession{
    if (self = [super init]) {
        self.clientID = clientId;
        self.port = 1883;
        self.keepAlive = 60;
        self.reconnectDelay = 1;
        self.reconnectDelayMax = 1;
        self.reconnectExponentialBackoff = NO;

        self.subscriptionHandlers = [[NSMutableDictionary alloc] init];
        self.unsubscriptionHandlers = [[NSMutableDictionary alloc] init];
        self.publishHandlers = [[NSMutableDictionary alloc] init];
        self.cleanSession = cleanSession;

#ifdef WITH_TLS
    
        self.tlsVersion = MQTTKitTLSVersion1_2;
        self.tlsInsecure = NO;
        self.tlsPeerCertVerify = NO;
        
#endif
        
        const char* cstrClientId = [self.clientID cStringUsingEncoding:NSUTF8StringEncoding];

        mosq = mosquitto_new(cstrClientId, self.cleanSession, (__bridge void *)(self));
        mosquitto_connect_callback_set(mosq, on_connect);
        mosquitto_disconnect_callback_set(mosq, on_disconnect);
        mosquitto_publish_callback_set(mosq, on_publish);
        mosquitto_message_callback_set(mosq, on_message);
        mosquitto_subscribe_callback_set(mosq, on_subscribe);
        mosquitto_unsubscribe_callback_set(mosq, on_unsubscribe);
        mosquitto_log_callback_set(mosq, on_log);
        
        self.queue = dispatch_queue_create(cstrClientId, NULL);
    }
    return self;
}

- (int) setMaxInflightMessages:(NSUInteger)maxInflightMessages{
    return mosquitto_max_inflight_messages_set(mosq, (unsigned int)maxInflightMessages);
}

- (void) setMessageRetry: (NSUInteger)seconds{
    mosquitto_message_retry_set(mosq, (unsigned int)seconds);
}

- (void) dealloc {
    if (mosq) {
        mosquitto_lib_cleanup();
        mosquitto_destroy(mosq);
        mosq = NULL;
    }
}

#pragma mark - Connection

- (int) connectWithCompletionHandler:(void (^)(MQTTConnectionReturnCode code))completionHandler {
    self.connectionCompletionHandler = completionHandler;

    int res;
    
    const char *cstrHost = [self.host cStringUsingEncoding:NSASCIIStringEncoding];
    const char *cstrUsername = NULL, *cstrPassword = NULL;
    
    if (self.username)
        cstrUsername = [self.username cStringUsingEncoding:NSUTF8StringEncoding];
    
    if (self.password)
        cstrPassword = [self.password cStringUsingEncoding:NSUTF8StringEncoding];
    
    
    
    res = mosquitto_username_pw_set(mosq, cstrUsername, cstrPassword);
    res *= 10;
    
    res += mosquitto_reconnect_delay_set(mosq, self.reconnectDelay, self.reconnectDelayMax, self.reconnectExponentialBackoff);
    res *= 10;

#ifdef WITH_TLS
    const char *cstrTLSCafile = NULL, *cstrTLSCerPath = NULL, *cstrTLSCerKeyPath = NULL;
    
    if (self.tlsCafile)
        cstrTLSCafile = [self.tlsCafile cStringUsingEncoding:NSUTF8StringEncoding];
    if (self.tlsCerPath)
        cstrTLSCerPath = [self.tlsCerPath cStringUsingEncoding:NSUTF8StringEncoding];
    if (self.tlsCerKeyPath)
        cstrTLSCerKeyPath = [self.tlsCerKeyPath cStringUsingEncoding:NSUTF8StringEncoding];
    
    res += mosquitto_tls_set(mosq, cstrTLSCafile, NULL, cstrTLSCerPath, cstrTLSCerKeyPath, NULL);
    res *= 100;
    
    const char *cstrTLSVersion = NULL, *cstrTLSCiphers = NULL;
    if (self.tlsVersion)
        cstrTLSVersion = [self.tlsVersion cStringUsingEncoding:NSUTF8StringEncoding];
    if (self.tlsCiphers)
        cstrTLSCiphers = [self.tlsCiphers cStringUsingEncoding:NSUTF8StringEncoding];
    
    res += mosquitto_tls_opts_set(mosq, self.tlsPeerCertVerify?1:0, cstrTLSVersion, cstrTLSCiphers);
    res *= 10;
    
    res += mosquitto_tls_insecure_set(mosq, self.tlsInsecure?true:false);
#endif
    
    res += mosquitto_connect(mosq, cstrHost, self.port, self.keepAlive);
    res *= 10;
    
    if (!res)
    {
        dispatch_async(self.queue, ^{
            LogDebug(@"start mosquitto loop on %@", self.queue);
            mosquitto_loop_forever(mosq, -1, 1);
            LogDebug(@"end mosquitto loop on %@", self.queue);
        });
    }
  
    return res;
}

- (int)connectToHost:(NSString *)host
    completionHandler:(void (^)(MQTTConnectionReturnCode code))completionHandler {
    self.host = host;
    return [self connectWithCompletionHandler:completionHandler];
}

- (int) reconnect {
    return mosquitto_reconnect(mosq);
}

- (int) disconnectWithCompletionHandler:(MQTTDisconnectionHandler)completionHandler {
    if (completionHandler) {
        self.disconnectionHandler = completionHandler;
    }
    return mosquitto_disconnect(mosq);
}

- (int)setWillData:(NSData *)payload
            toTopic:(NSString *)willTopic
            withQos:(MQTTQualityOfService)willQos
             retain:(BOOL)retain
{
    const char* cstrTopic = [willTopic cStringUsingEncoding:NSUTF8StringEncoding];
    return mosquitto_will_set(mosq, cstrTopic, (int)payload.length, payload.bytes, willQos, retain);
}

- (int)setWill:(NSString *)payload
        toTopic:(NSString *)willTopic
        withQos:(MQTTQualityOfService)willQos
         retain:(BOOL)retain;
{
    return [self setWillData:[payload dataUsingEncoding:NSUTF8StringEncoding]
              toTopic:willTopic
              withQos:willQos
               retain:retain];
}

- (int)clearWill
{
    return mosquitto_will_clear(mosq);
}

#pragma mark - Publish

- (int)publishData:(NSData *)payload
            toTopic:(NSString *)topic
            withQos:(MQTTQualityOfService)qos
             retain:(BOOL)retain
  completionHandler:(void (^)(int mid))completionHandler {
    const char* cstrTopic = [topic cStringUsingEncoding:NSUTF8StringEncoding];
    if (qos == 0 && completionHandler) {
        [self.publishHandlers setObject:completionHandler forKey:[NSNumber numberWithInt:0]];
    }
    int mid, res;
    res = mosquitto_publish(mosq, &mid, cstrTopic, (int)payload.length, payload.bytes, qos, retain);

    if (!res){
        if (completionHandler) {
            if (qos == 0) {
                completionHandler(mid);
            } else {
                [self.publishHandlers setObject:completionHandler forKey:[NSNumber numberWithInt:mid]];
            }
        }
    }
    return res;
}

- (int)publishString:(NSString *)payload
              toTopic:(NSString *)topic
              withQos:(MQTTQualityOfService)qos
               retain:(BOOL)retain
    completionHandler:(void (^)(int mid))completionHandler; {
    return [self publishData:[payload dataUsingEncoding:NSUTF8StringEncoding]
              toTopic:topic
              withQos:qos
               retain:retain
    completionHandler:completionHandler];
}

#pragma mark - Subscribe

- (int)subscribe: (NSString *)topic withCompletionHandler:(MQTTSubscriptionCompletionHandler)completionHandler {
    return [self subscribe:topic withQos:0 completionHandler:completionHandler];
}

- (int)subscribe: (NSString *)topic withQos:(MQTTQualityOfService)qos completionHandler:(MQTTSubscriptionCompletionHandler)completionHandler
{
    const char* cstrTopic = [topic cStringUsingEncoding:NSUTF8StringEncoding];
    int mid, res;
    res = mosquitto_subscribe(mosq, &mid, cstrTopic, qos);
    if (!res){
        if (completionHandler) {
            [self.subscriptionHandlers setObject:[completionHandler copy] forKey:[NSNumber numberWithInteger:mid]];
        }
    }
    return res;
}

- (int)unsubscribe: (NSString *)topic withCompletionHandler:(void (^)(void))completionHandler
{
    const char* cstrTopic = [topic cStringUsingEncoding:NSUTF8StringEncoding];
    int mid, res;
    res = mosquitto_unsubscribe(mosq, &mid, cstrTopic);
    if (!res){
        if (completionHandler) {
            [self.unsubscriptionHandlers setObject:[completionHandler copy] forKey:[NSNumber numberWithInteger:mid]];
        }
    }
    return res;
}

@end
