// PassKitCore: the PassKit classes WebKit reaches through PAL's PassKitCore soft link, from a private
// framework 10.9 does not ship at all. Every class here is registered with WK_POLYFILL_CLASS, so the
// dlopen of the framework path is answered with the layer's absent-provider token; the C functions
// and constants are in c/PassKitCore.m.
//
// This system has no Apple Pay: PassKitMacHelper, which vends the payment sheet, and PassKitUI, which
// vends payment setup, do not exist, so WebKit's own checks report that no payment can be made and no
// sheet is shown. The classes below are what remains reachable without a sheet: the networks a payment
// request may name, payment-setup and active-card queries that answer no, and the value types WebKit's
// IPC layer names. Each value type carries what its creator sets and archives under the keys WebKit's
// CoreIPC wrappers read and write (Source/WebKit/Shared/Cocoa/CoreIPCPK*.mm).
#import "wk_priv_class.h"
#import <Foundation/Foundation.h>

#define WK_PASSKITCORE "/System/Library/PrivateFrameworks/PassKitCore.framework/PassKitCore"

typedef NSUInteger PKPaymentSummaryItemType;
typedef NSUInteger PKPaymentMethodType;
typedef NSInteger PKSecureElementPassActivationState;

WK_PRIV_CLASS(CNContact) @interface CNContact : NSObject
@end
WK_PRIV_CLASS(CNPhoneNumber) @interface CNPhoneNumber : NSObject
@end
WK_PRIV_CLASS(CNPostalAddress) @interface CNPostalAddress : NSObject
@end
WK_PRIV_CLASS(NSPersonNameComponents) @interface NSPersonNameComponents : NSObject
@end

// Declared only, so the value classes below can name each other's coding tables.
@interface NSObject (WKPolyfillPassKitCoding)
+ (NSDictionary *)wk_codingClasses;
@end

// Sets or, for nil, removes; a copyable value is copied.
static void wkStoreValue(NSMutableDictionary *values, NSString *key, id value)
{
    if (!value) {
        [values removeObjectForKey:key];
        return;
    }
    id stored = [value conformsToProtocol:@protocol(NSCopying)] ? [value copy] : [value retain];
    [values setObject:stored forKey:key];
    [stored release];
}

static void wkDecodeValues(NSCoder *coder, NSDictionary *classesByKey, NSMutableDictionary *values)
{
    for (NSString *key in classesByKey) {
        NSSet *classes = [classesByKey objectForKey:key];
        if ([classes count])
            wkStoreValue(values, key, [coder decodeObjectOfClasses:classes forKey:key]);
    }
}

static void wkEncodeValues(NSCoder *coder, NSDictionary *values)
{
    for (NSString *key in values)
        [coder encodeObject:[values objectForKey:key] forKey:key];
}

// The members every value class here shares: its values live in _values under their coding keys, and
// +wk_codingClasses names the classes each key may decode as.
#define WK_PK_VALUE_CLASS_MEMBERS                                                            \
    + (BOOL)supportsSecureCoding { return YES; }                                             \
    - (instancetype)init                                                                     \
    {                                                                                        \
        if (!(self = [super init]))                                                          \
            return nil;                                                                      \
        _values = [[NSMutableDictionary alloc] init];                                        \
        return self;                                                                         \
    }                                                                                        \
    - (void)dealloc                                                                          \
    {                                                                                        \
        [_values release];                                                                   \
        [super dealloc];                                                                     \
    }                                                                                        \
    - (instancetype)initWithCoder:(NSCoder *)coder                                           \
    {                                                                                        \
        if (!(self = [self init]))                                                           \
            return nil;                                                                      \
        wkDecodeValues(coder, [[self class] wk_codingClasses], _values);                     \
        return self;                                                                         \
    }                                                                                        \
    - (void)encodeWithCoder:(NSCoder *)coder { wkEncodeValues(coder, _values); }              \
    - (BOOL)isEqual:(id)other                                                                \
    {                                                                                        \
        return [other class] == [self class]                                                 \
            && [_values isEqualToDictionary:((__typeof__(self))other)->_values];             \
    }                                                                                        \
    - (NSUInteger)hash { return [_values count]; }

#define WK_PK_STRING(key) @key : [NSSet setWithObject:[NSString class]]
#define WK_PK_NUMBER(key) @key : [NSSet setWithObject:[NSNumber class]]
#define WK_PK_DATA(key) @key : [NSSet setWithObject:[NSData class]]

#pragma mark - PKPaymentRequest

// A PKPaymentRequest instance is built only to present PassKitMacHelper's sheet, so the class answers
// the one question asked of it without a sheet: which payment networks a request may name. The list is
// Apple's "Supporting payment networks" table for Apple Pay on the Web (developer.apple.com,
// applepayontheweb/supported-networks), which WebKit matches case-insensitively, with the two earlier
// spellings of Cartes Bancaires that Apple Pay versions before 4 accept.
WK_PRIV_CLASS(PKPaymentRequest) @interface PKPaymentRequest : NSObject
+ (NSArray *)availableNetworks;
@end

@implementation PKPaymentRequest

+ (NSArray *)availableNetworks
{
    return @[ @"amex", @"bancomat", @"bancontact", @"bankAxept", @"carteBancaire", @"carteBancaires", @"cartesBancaires",
        @"chinaUnionPay", @"dankort", @"discover", @"eftpos", @"electron", @"elo", @"girocard", @"himyan", @"interac",
        @"jaywan", @"jcb", @"mada", @"maestro", @"masterCard", @"meeza", @"mir", @"myDebit", @"NAPAS", @"postFinanceAG",
        @"privateLabel", @"quicPay", @"visa", @"vPay" ];
}

@end
WK_PRIV_ALIAS(PKPaymentRequest);
WK_POLYFILL_CLASS(WK_PASSKITCORE, PKPaymentRequest);

#pragma mark - PKPassLibrary

WK_PRIV_CLASS(PKPassLibrary) @interface PKPassLibrary : NSObject
- (void)openPaymentSetupForMerchantIdentifier:(NSString *)merchantIdentifier domain:(NSString *)domain completion:(void (^)(BOOL success))completion;
@end

@implementation PKPassLibrary

// Payment setup is PassKitUI's, which this system lacks, so it is never opened.
- (void)openPaymentSetupForMerchantIdentifier:(NSString *)merchantIdentifier domain:(NSString *)domain completion:(void (^)(BOOL success))completion
{
    if (!completion)
        return;
    void (^reply)(BOOL) = [[completion copy] autorelease];
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        reply(NO);
    });
}

@end
WK_PRIV_ALIAS(PKPassLibrary);
WK_POLYFILL_CLASS(WK_PASSKITCORE, PKPassLibrary);

#pragma mark - PKDateComponentsRange

WK_PRIV_CLASS(PKDateComponentsRange) @interface PKDateComponentsRange : NSObject <NSCopying, NSSecureCoding> {
    NSMutableDictionary *_values;
}
- (instancetype)initWithStartDateComponents:(NSDateComponents *)startDateComponents endDateComponents:(NSDateComponents *)endDateComponents;
@property (nonatomic, readonly, copy) NSDateComponents *startDateComponents;
@property (nonatomic, readonly, copy) NSDateComponents *endDateComponents;
@end

@implementation PKDateComponentsRange

WK_PK_VALUE_CLASS_MEMBERS

+ (NSDictionary *)wk_codingClasses
{
    return @{
        @"startDateComponents" : [NSSet setWithObject:[NSDateComponents class]],
        @"endDateComponents" : [NSSet setWithObject:[NSDateComponents class]],
    };
}

- (instancetype)initWithStartDateComponents:(NSDateComponents *)startDateComponents endDateComponents:(NSDateComponents *)endDateComponents
{
    if (!startDateComponents || !endDateComponents) {
        [self release];
        return nil;
    }
    if (!(self = [self init]))
        return nil;
    wkStoreValue(_values, @"startDateComponents", startDateComponents);
    wkStoreValue(_values, @"endDateComponents", endDateComponents);
    return self;
}

- (NSDateComponents *)startDateComponents { return [_values objectForKey:@"startDateComponents"]; }
- (NSDateComponents *)endDateComponents { return [_values objectForKey:@"endDateComponents"]; }

- (id)copyWithZone:(NSZone *)zone
{
    return [self retain];
}

@end
WK_PRIV_ALIAS(PKDateComponentsRange);
WK_POLYFILL_CLASS(WK_PASSKITCORE, PKDateComponentsRange);

#pragma mark - PKPaymentSummaryItem, PKShippingMethod

WK_PRIV_CLASS(PKPaymentSummaryItem) @interface PKPaymentSummaryItem : NSObject <NSSecureCoding> {
@protected
    NSMutableDictionary *_values;
}
+ (instancetype)summaryItemWithLabel:(NSString *)label amount:(NSDecimalNumber *)amount;
+ (instancetype)summaryItemWithLabel:(NSString *)label amount:(NSDecimalNumber *)amount type:(PKPaymentSummaryItemType)type;
@property (nonatomic, copy) NSString *label;
@property (nonatomic, copy) NSDecimalNumber *amount;
@property (nonatomic, assign) PKPaymentSummaryItemType type;
@end

@implementation PKPaymentSummaryItem

WK_PK_VALUE_CLASS_MEMBERS

+ (NSDictionary *)wk_codingClasses
{
    return @{
        WK_PK_STRING("label"),
        WK_PK_NUMBER("amount"),
        WK_PK_NUMBER("type"),
        WK_PK_STRING("localizedTitle"),
        WK_PK_STRING("localizedAmount"),
        WK_PK_NUMBER("useDarkColor"),
        WK_PK_NUMBER("useLargeFont"),
    };
}

+ (instancetype)summaryItemWithLabel:(NSString *)label amount:(NSDecimalNumber *)amount
{
    return [self summaryItemWithLabel:label amount:amount type:0];
}

+ (instancetype)summaryItemWithLabel:(NSString *)label amount:(NSDecimalNumber *)amount type:(PKPaymentSummaryItemType)type
{
    PKPaymentSummaryItem *item = [[[self alloc] init] autorelease];
    item.label = label;
    item.amount = amount;
    item.type = type;
    return item;
}

- (NSString *)label { return [_values objectForKey:@"label"]; }
- (void)setLabel:(NSString *)label { wkStoreValue(_values, @"label", label); }

// An archived amount may decode as any NSNumber; it reads back as the decimal it holds.
- (NSDecimalNumber *)amount
{
    NSNumber *amount = [_values objectForKey:@"amount"];
    if (!amount || [amount isKindOfClass:[NSDecimalNumber class]])
        return (NSDecimalNumber *)amount;
    return [NSDecimalNumber decimalNumberWithDecimal:[amount decimalValue]];
}
- (void)setAmount:(NSDecimalNumber *)amount { wkStoreValue(_values, @"amount", amount); }

- (PKPaymentSummaryItemType)type { return [[_values objectForKey:@"type"] unsignedCharValue]; }
- (void)setType:(PKPaymentSummaryItemType)type { wkStoreValue(_values, @"type", [NSNumber numberWithUnsignedChar:(unsigned char)type]); }

@end
WK_PRIV_ALIAS(PKPaymentSummaryItem);
WK_POLYFILL_CLASS(WK_PASSKITCORE, PKPaymentSummaryItem);

WK_PRIV_CLASS(PKShippingMethod) @interface PKShippingMethod : PKPaymentSummaryItem
@property (nonatomic, copy) NSString *identifier;
@property (nonatomic, copy) NSString *detail;
@property (nonatomic, copy) PKDateComponentsRange *dateComponentsRange;
@end

@implementation PKShippingMethod

+ (NSDictionary *)wk_codingClasses
{
    NSMutableDictionary *classes = [[[super wk_codingClasses] mutableCopy] autorelease];
    [classes addEntriesFromDictionary:@{
        WK_PK_STRING("identifier"),
        WK_PK_STRING("detail"),
        @"dateComponentsRange" : [NSSet setWithObject:[PKDateComponentsRange class]],
    }];
    return classes;
}

- (NSString *)identifier { return [_values objectForKey:@"identifier"]; }
- (void)setIdentifier:(NSString *)identifier { wkStoreValue(_values, @"identifier", identifier); }
- (NSString *)detail { return [_values objectForKey:@"detail"]; }
- (void)setDetail:(NSString *)detail { wkStoreValue(_values, @"detail", detail); }
- (PKDateComponentsRange *)dateComponentsRange { return [_values objectForKey:@"dateComponentsRange"]; }
- (void)setDateComponentsRange:(PKDateComponentsRange *)range { wkStoreValue(_values, @"dateComponentsRange", range); }

@end
WK_PRIV_ALIAS(PKShippingMethod);
WK_POLYFILL_CLASS(WK_PASSKITCORE, PKShippingMethod);

#pragma mark - PKContact

WK_PRIV_CLASS(PKContact) @interface PKContact : NSObject <NSSecureCoding> {
    NSMutableDictionary *_values;
}
@property (nonatomic, strong) NSPersonNameComponents *name;
@property (nonatomic, strong) CNPostalAddress *postalAddress;
@property (nonatomic, strong) NSString *emailAddress;
@property (nonatomic, strong) CNPhoneNumber *phoneNumber;
@property (nonatomic, copy) NSString *supplementarySubLocality;
@end

@implementation PKContact

WK_PK_VALUE_CLASS_MEMBERS

+ (NSDictionary *)wk_codingClasses
{
    return @{
        @"name" : [NSSet setWithObject:[NSPersonNameComponents class]],
        @"postalAddress" : [NSSet setWithObject:[CNPostalAddress class]],
        WK_PK_STRING("emailAddress"),
        @"phoneNumber" : [NSSet setWithObject:[CNPhoneNumber class]],
        WK_PK_STRING("supplementarySubLocality"),
    };
}

- (NSPersonNameComponents *)name { return [_values objectForKey:@"name"]; }
- (void)setName:(NSPersonNameComponents *)name { wkStoreValue(_values, @"name", name); }
- (CNPostalAddress *)postalAddress { return [_values objectForKey:@"postalAddress"]; }
- (void)setPostalAddress:(CNPostalAddress *)address { wkStoreValue(_values, @"postalAddress", address); }
- (NSString *)emailAddress { return [_values objectForKey:@"emailAddress"]; }
- (void)setEmailAddress:(NSString *)emailAddress { wkStoreValue(_values, @"emailAddress", emailAddress); }
- (CNPhoneNumber *)phoneNumber { return [_values objectForKey:@"phoneNumber"]; }
- (void)setPhoneNumber:(CNPhoneNumber *)phoneNumber { wkStoreValue(_values, @"phoneNumber", phoneNumber); }
- (NSString *)supplementarySubLocality { return [_values objectForKey:@"supplementarySubLocality"]; }
- (void)setSupplementarySubLocality:(NSString *)value { wkStoreValue(_values, @"supplementarySubLocality", value); }

@end
WK_PRIV_ALIAS(PKContact);
WK_POLYFILL_CLASS(WK_PASSKITCORE, PKContact);

#pragma mark - PKPass, PKSecureElementPass, PKPaymentPass

WK_PRIV_CLASS(PKPass) @interface PKPass : NSObject <NSSecureCoding> {
@protected
    NSMutableDictionary *_values;
}
@property (nonatomic, copy, readonly) NSString *serialNumber;
@property (nonatomic, copy, readonly) NSString *passTypeIdentifier;
@property (nonatomic, copy, readonly) NSURL *webServiceURL;
@property (nonatomic, copy, readonly) NSString *authenticationToken;
@property (nonatomic, copy, readonly) NSString *localizedName;
@property (nonatomic, copy, readonly) NSString *localizedDescription;
@property (nonatomic, copy, readonly) NSString *organizationName;
@property (nonatomic, copy, readonly) NSDate *relevantDate;
@property (nonatomic, copy, readonly) NSDictionary *userInfo;
@property (nonatomic, copy, readonly) NSURL *passURL;
@property (nonatomic, readonly, getter=isRemotePass) BOOL remotePass;
@property (nonatomic, copy, readonly) NSString *deviceName;
@end

@implementation PKPass

WK_PK_VALUE_CLASS_MEMBERS

+ (NSDictionary *)wk_codingClasses
{
    return @{
        WK_PK_STRING("serialNumber"),
        WK_PK_STRING("passTypeIdentifier"),
        @"webServiceURL" : [NSSet setWithObject:[NSURL class]],
        WK_PK_STRING("authenticationToken"),
        WK_PK_STRING("localizedName"),
        WK_PK_STRING("localizedDescription"),
        WK_PK_STRING("organizationName"),
        @"relevantDate" : [NSSet setWithObject:[NSDate class]],
        @"userInfo" : [NSSet setWithObject:[NSDictionary class]],
        @"passURL" : [NSSet setWithObject:[NSURL class]],
        WK_PK_NUMBER("remotePass"),
        WK_PK_STRING("deviceName"),
    };
}

- (NSString *)serialNumber { return [_values objectForKey:@"serialNumber"]; }
- (NSString *)passTypeIdentifier { return [_values objectForKey:@"passTypeIdentifier"]; }
- (NSURL *)webServiceURL { return [_values objectForKey:@"webServiceURL"]; }
- (NSString *)authenticationToken { return [_values objectForKey:@"authenticationToken"]; }
- (NSString *)localizedName { return [_values objectForKey:@"localizedName"]; }
- (NSString *)localizedDescription { return [_values objectForKey:@"localizedDescription"]; }
- (NSString *)organizationName { return [_values objectForKey:@"organizationName"]; }
- (NSDate *)relevantDate { return [_values objectForKey:@"relevantDate"]; }
- (NSDictionary *)userInfo { return [_values objectForKey:@"userInfo"]; }
- (NSURL *)passURL { return [_values objectForKey:@"passURL"]; }
- (BOOL)isRemotePass { return [[_values objectForKey:@"remotePass"] boolValue]; }
- (NSString *)deviceName { return [_values objectForKey:@"deviceName"]; }

@end
WK_PRIV_ALIAS(PKPass);

WK_PRIV_CLASS(PKSecureElementPass) @interface PKSecureElementPass : PKPass
@property (nonatomic, readonly) NSString *primaryAccountIdentifier;
@property (nonatomic, readonly) NSString *primaryAccountNumberSuffix;
@property (nonatomic, readonly) NSString *deviceAccountIdentifier;
@property (nonatomic, readonly) NSString *deviceAccountNumberSuffix;
@property (nonatomic, readonly) PKSecureElementPassActivationState passActivationState;
@property (nonatomic, readonly) NSString *devicePassIdentifier;
@property (nonatomic, readonly) NSString *pairedTerminalIdentifier;
@end

@implementation PKSecureElementPass

+ (NSDictionary *)wk_codingClasses
{
    NSMutableDictionary *classes = [[[super wk_codingClasses] mutableCopy] autorelease];
    [classes addEntriesFromDictionary:@{
        WK_PK_STRING("primaryAccountIdentifier"),
        WK_PK_STRING("primaryAccountNumberSuffix"),
        WK_PK_STRING("deviceAccountIdentifier"),
        WK_PK_STRING("deviceAccountNumberSuffix"),
        WK_PK_NUMBER("passActivationState"),
        WK_PK_STRING("devicePassIdentifier"),
        WK_PK_STRING("pairedTerminalIdentifier"),
    }];
    return classes;
}

- (NSString *)primaryAccountIdentifier { return [_values objectForKey:@"primaryAccountIdentifier"]; }
- (NSString *)primaryAccountNumberSuffix { return [_values objectForKey:@"primaryAccountNumberSuffix"]; }
- (NSString *)deviceAccountIdentifier { return [_values objectForKey:@"deviceAccountIdentifier"]; }
- (NSString *)deviceAccountNumberSuffix { return [_values objectForKey:@"deviceAccountNumberSuffix"]; }
- (PKSecureElementPassActivationState)passActivationState { return [[_values objectForKey:@"passActivationState"] integerValue]; }
- (NSString *)devicePassIdentifier { return [_values objectForKey:@"devicePassIdentifier"]; }
- (NSString *)pairedTerminalIdentifier { return [_values objectForKey:@"pairedTerminalIdentifier"]; }

@end
WK_PRIV_ALIAS(PKSecureElementPass);
WK_POLYFILL_CLASS(WK_PASSKITCORE, PKSecureElementPass);

WK_PRIV_CLASS(PKPaymentPass) @interface PKPaymentPass : PKSecureElementPass
@property (nonatomic, readonly) NSInteger activationState;
@end

@implementation PKPaymentPass

- (NSInteger)activationState
{
    return [self passActivationState];
}

@end
WK_PRIV_ALIAS(PKPaymentPass);
WK_POLYFILL_CLASS(WK_PASSKITCORE, PKPaymentPass);

#pragma mark - PKPaymentMethod, PKPaymentToken, PKPayment

WK_PRIV_CLASS(PKPaymentMethod) @interface PKPaymentMethod : NSObject <NSSecureCoding> {
    NSMutableDictionary *_values;
}
@property (nonatomic, copy) NSString *displayName;
@property (nonatomic, copy) NSString *network;
@property (nonatomic) PKPaymentMethodType type;
@property (nonatomic, copy) PKPaymentPass *paymentPass;
@property (nonatomic, copy) PKSecureElementPass *secureElementPass;
@property (nonatomic, copy) CNContact *billingAddress;
@property (nonatomic, copy) NSString *bindToken;
@property (nonatomic, copy) NSString *peerPaymentQuoteIdentifier;
@property (nonatomic) BOOL usePeerPaymentBalance;
@end

@implementation PKPaymentMethod

WK_PK_VALUE_CLASS_MEMBERS

+ (NSDictionary *)wk_codingClasses
{
    return @{
        WK_PK_NUMBER("type"),
        WK_PK_STRING("displayName"),
        WK_PK_STRING("network"),
        @"paymentPass" : [NSSet setWithObject:[PKSecureElementPass class]],
        WK_PK_STRING("peerPaymentQuoteIdentifier"),
        @"billingAddress" : [NSSet setWithObject:[CNContact class]],
        WK_PK_STRING("installmentBindToken"),
        WK_PK_NUMBER("usePeerPaymentBalance"),
    };
}

- (NSString *)displayName { return [_values objectForKey:@"displayName"]; }
- (NSString *)network { return [_values objectForKey:@"network"]; }
- (PKPaymentMethodType)type { return [[_values objectForKey:@"type"] unsignedCharValue]; }
- (PKSecureElementPass *)secureElementPass { return [_values objectForKey:@"paymentPass"]; }
- (CNContact *)billingAddress { return [_values objectForKey:@"billingAddress"]; }
- (NSString *)bindToken { return [_values objectForKey:@"installmentBindToken"]; }

- (PKPaymentPass *)paymentPass
{
    id pass = [_values objectForKey:@"paymentPass"];
    return [pass isKindOfClass:[PKPaymentPass class]] ? pass : nil;
}

- (NSString *)peerPaymentQuoteIdentifier { return [_values objectForKey:@"peerPaymentQuoteIdentifier"]; }
- (BOOL)usePeerPaymentBalance { return [[_values objectForKey:@"usePeerPaymentBalance"] boolValue]; }

- (void)setDisplayName:(NSString *)value { wkStoreValue(_values, @"displayName", value); }
- (void)setNetwork:(NSString *)value { wkStoreValue(_values, @"network", value); }
- (void)setType:(PKPaymentMethodType)value { wkStoreValue(_values, @"type", [NSNumber numberWithUnsignedChar:(unsigned char)value]); }
- (void)setPaymentPass:(PKPaymentPass *)value { wkStoreValue(_values, @"paymentPass", value); }
- (void)setSecureElementPass:(PKSecureElementPass *)value { wkStoreValue(_values, @"paymentPass", value); }
- (void)setBillingAddress:(CNContact *)value { wkStoreValue(_values, @"billingAddress", value); }
- (void)setBindToken:(NSString *)value { wkStoreValue(_values, @"installmentBindToken", value); }
- (void)setPeerPaymentQuoteIdentifier:(NSString *)value { wkStoreValue(_values, @"peerPaymentQuoteIdentifier", value); }
- (void)setUsePeerPaymentBalance:(BOOL)value { wkStoreValue(_values, @"usePeerPaymentBalance", @(value)); }

@end
WK_PRIV_ALIAS(PKPaymentMethod);
WK_POLYFILL_CLASS(WK_PASSKITCORE, PKPaymentMethod);

WK_PRIV_CLASS(PKPaymentToken) @interface PKPaymentToken : NSObject <NSSecureCoding> {
    NSMutableDictionary *_values;
}
@property (nonatomic, strong) PKPaymentMethod *paymentMethod;
@property (nonatomic, copy) NSString *paymentInstrumentName;
@property (nonatomic, copy) NSString *paymentNetwork;
@property (nonatomic, copy) NSString *transactionIdentifier;
@property (nonatomic, copy) NSData *paymentData;
@property (nonatomic, copy) NSURL *redeemURL;
@property (nonatomic, copy) NSString *retryNonce;
@end

@implementation PKPaymentToken

WK_PK_VALUE_CLASS_MEMBERS

+ (NSDictionary *)wk_codingClasses
{
    return @{
        WK_PK_STRING("paymentInstrumentName"),
        WK_PK_STRING("paymentNetwork"),
        WK_PK_STRING("transactionIdentifier"),
        WK_PK_DATA("paymentData"),
        @"paymentMethod" : [NSSet setWithObject:[PKPaymentMethod class]],
        @"redeemURL" : [NSSet setWithObject:[NSURL class]],
        WK_PK_STRING("retryNonce"),
    };
}

- (PKPaymentMethod *)paymentMethod { return [_values objectForKey:@"paymentMethod"]; }
- (NSString *)paymentInstrumentName { return [_values objectForKey:@"paymentInstrumentName"]; }
- (NSString *)paymentNetwork { return [_values objectForKey:@"paymentNetwork"]; }
- (NSString *)transactionIdentifier { return [_values objectForKey:@"transactionIdentifier"]; }
- (NSData *)paymentData { return [_values objectForKey:@"paymentData"]; }
- (NSURL *)redeemURL { return [_values objectForKey:@"redeemURL"]; }
- (NSString *)retryNonce { return [_values objectForKey:@"retryNonce"]; }

- (void)setPaymentMethod:(PKPaymentMethod *)value { wkStoreValue(_values, @"paymentMethod", value); }
- (void)setPaymentInstrumentName:(NSString *)value { wkStoreValue(_values, @"paymentInstrumentName", value); }
- (void)setPaymentNetwork:(NSString *)value { wkStoreValue(_values, @"paymentNetwork", value); }
- (void)setTransactionIdentifier:(NSString *)value { wkStoreValue(_values, @"transactionIdentifier", value); }
- (void)setPaymentData:(NSData *)value { wkStoreValue(_values, @"paymentData", value); }
- (void)setRedeemURL:(NSURL *)value { wkStoreValue(_values, @"redeemURL", value); }
- (void)setRetryNonce:(NSString *)value { wkStoreValue(_values, @"retryNonce", value); }

@end
WK_PRIV_ALIAS(PKPaymentToken);
WK_POLYFILL_CLASS(WK_PASSKITCORE, PKPaymentToken);

WK_PRIV_CLASS(PKPayment) @interface PKPayment : NSObject <NSSecureCoding> {
    NSMutableDictionary *_values;
}
@property (nonatomic, strong) PKPaymentToken *token;
@property (nonatomic, strong) PKContact *billingContact;
@property (nonatomic, strong) PKContact *shippingContact;
@property (nonatomic, strong) PKShippingMethod *shippingMethod;
@property (nonatomic, copy) NSData *credential;
@property (nonatomic, copy) NSDictionary *authKitAuthenticationResults;
@property (nonatomic, copy) NSNumber *biometryAttempts;
@property (nonatomic, copy) NSString *installmentAuthorizationToken;
@end

@implementation PKPayment

WK_PK_VALUE_CLASS_MEMBERS

+ (NSDictionary *)wk_codingClasses
{
    return @{
        @"token" : [NSSet setWithObject:[PKPaymentToken class]],
        @"shippingContact" : [NSSet setWithObject:[PKContact class]],
        @"billingContact" : [NSSet setWithObject:[PKContact class]],
        @"shippingMethod" : [NSSet setWithObject:[PKShippingMethod class]],
        WK_PK_DATA("credential"),
        @"authKitAuthenticationResults" : [NSSet setWithObject:[NSDictionary class]],
        WK_PK_NUMBER("biometryAttempts"),
        WK_PK_STRING("installmentAuthorizationToken"),
    };
}

- (PKPaymentToken *)token { return [_values objectForKey:@"token"]; }
- (PKContact *)billingContact { return [_values objectForKey:@"billingContact"]; }
- (PKContact *)shippingContact { return [_values objectForKey:@"shippingContact"]; }
- (PKShippingMethod *)shippingMethod { return [_values objectForKey:@"shippingMethod"]; }
- (NSString *)installmentAuthorizationToken { return [_values objectForKey:@"installmentAuthorizationToken"]; }
- (NSData *)credential { return [_values objectForKey:@"credential"]; }
- (NSDictionary *)authKitAuthenticationResults { return [_values objectForKey:@"authKitAuthenticationResults"]; }
- (NSNumber *)biometryAttempts { return [_values objectForKey:@"biometryAttempts"]; }

- (void)setToken:(PKPaymentToken *)value { wkStoreValue(_values, @"token", value); }
- (void)setBillingContact:(PKContact *)value { wkStoreValue(_values, @"billingContact", value); }
- (void)setShippingContact:(PKContact *)value { wkStoreValue(_values, @"shippingContact", value); }
- (void)setShippingMethod:(PKShippingMethod *)value { wkStoreValue(_values, @"shippingMethod", value); }
- (void)setCredential:(NSData *)value { wkStoreValue(_values, @"credential", value); }
- (void)setAuthKitAuthenticationResults:(NSDictionary *)value { wkStoreValue(_values, @"authKitAuthenticationResults", value); }
- (void)setBiometryAttempts:(NSNumber *)value { wkStoreValue(_values, @"biometryAttempts", value); }
- (void)setInstallmentAuthorizationToken:(NSString *)value { wkStoreValue(_values, @"installmentAuthorizationToken", value); }

@end
WK_PRIV_ALIAS(PKPayment);
WK_POLYFILL_CLASS(WK_PASSKITCORE, PKPayment);

#pragma mark - PKPaymentMerchantSession

// The merchant session a merchant's server signs, read from its JSON dictionary; the signature arrives
// as a hexadecimal string and is held as the bytes it spells.
WK_PRIV_CLASS(PKPaymentMerchantSession) @interface PKPaymentMerchantSession : NSObject <NSSecureCoding> {
    NSMutableDictionary *_values;
}
- (instancetype)initWithDictionary:(NSDictionary *)dictionary;
- (instancetype)initWithMerchantIdentifier:(NSString *)merchantIdentifier merchantSessionIdentifier:(NSString *)merchantSessionIdentifier nonce:(NSString *)nonce epochTimestamp:(NSUInteger)epochTimestamp expiresAt:(NSUInteger)expiresAt displayName:(NSString *)displayName initiativeContext:(NSString *)initiativeContext initiative:(NSString *)initiative ampEnrollmentPinning:(NSData *)ampEnrollmentPinning operationalAnalyticsIdentifier:(NSString *)operationalAnalyticsIdentifier signedFields:(NSArray *)signedFields signature:(NSData *)signature;
- (instancetype)initWithMerchantIdentifier:(NSString *)merchantIdentifier merchantSessionIdentifier:(NSString *)merchantSessionIdentifier nonce:(NSString *)nonce epochTimestamp:(NSUInteger)epochTimestamp expiresAt:(NSUInteger)expiresAt domain:(NSString *)domainName displayName:(NSString *)displayName operationalAnalyticsIdentifier:(NSString *)operationalAnalyticsIdentifier signature:(NSData *)signature;
- (instancetype)initWithDelegateDisplayName:(NSString *)delegateDisplayName merchantIdentifier:(NSString *)merchantIdentifier displayName:(NSString *)displayName initiative:(NSString *)initiative initiativeContext:(NSString *)initiativeContext merchantSessionIdentifier:(NSString *)merchantSessionIdentifier nonce:(NSString *)nonce epochTimestamp:(NSUInteger)epochTimestamp expiresAt:(NSUInteger)expiresAt operationalAnalyticsIdentifier:(NSString *)operationalAnalyticsIdentifier signedFields:(NSArray *)signedFields signature:(NSData *)signature;
@property (nonatomic, readonly) NSString *merchantIdentifier;
@property (nonatomic, readonly) NSString *merchantSessionIdentifier;
@property (nonatomic, readonly) NSString *nonce;
@property (nonatomic, readonly) NSString *domainName;
@property (nonatomic, readonly) NSString *displayName;
@property (nonatomic, readonly) NSData *signature;
@end

static NSData *wkDataFromHexString(NSString *string)
{
    NSUInteger length = [string length];
    if (length % 2)
        return nil;
    NSMutableData *data = [NSMutableData dataWithLength:length / 2];
    unsigned char *bytes = [data mutableBytes];
    for (NSUInteger i = 0; i < length; i += 2) {
        unsigned value = 0;
        for (NSUInteger j = 0; j < 2; ++j) {
            unichar c = [string characterAtIndex:i + j];
            unsigned digit;
            if (c >= '0' && c <= '9')
                digit = c - '0';
            else if (c >= 'a' && c <= 'f')
                digit = c - 'a' + 10;
            else if (c >= 'A' && c <= 'F')
                digit = c - 'A' + 10;
            else
                return nil;
            value = value * 16 + digit;
        }
        bytes[i / 2] = (unsigned char)value;
    }
    return data;
}

@implementation PKPaymentMerchantSession

WK_PK_VALUE_CLASS_MEMBERS

+ (NSDictionary *)wk_codingClasses
{
    return @{
        WK_PK_STRING("merchantIdentifier"),
        WK_PK_STRING("merchantSessionIdentifier"),
        WK_PK_STRING("nonce"),
        WK_PK_NUMBER("epochTimestamp"),
        WK_PK_NUMBER("expiresAt"),
        WK_PK_STRING("domainName"),
        WK_PK_STRING("displayName"),
        WK_PK_DATA("signature"),
        WK_PK_STRING("retryNonce"),
        WK_PK_STRING("initiativeContext"),
        WK_PK_STRING("initiative"),
        WK_PK_DATA("ampEnrollmentPinning"),
        WK_PK_STRING("operationalAnalyticsIdentifier"),
        @"signedFields" : [NSSet setWithObject:[NSArray class]],
        WK_PK_NUMBER("isDelegatedSession"),
        WK_PK_STRING("delegateDisplayName"),
    };
}

- (instancetype)initWithDictionary:(NSDictionary *)dictionary
{
    if (!(self = [self init]))
        return nil;
    NSDictionary *classesByKey = [[self class] wk_codingClasses];
    for (NSString *key in classesByKey) {
        id value = [dictionary objectForKey:key];
        if ([value isKindOfClass:[NSString class]] && [[classesByKey objectForKey:key] containsObject:[NSData class]])
            value = wkDataFromHexString(value);
        for (Class cls in [classesByKey objectForKey:key]) {
            if ([value isKindOfClass:cls]) {
                wkStoreValue(_values, key, value);
                break;
            }
        }
    }
    return self;
}

- (instancetype)initWithMerchantIdentifier:(NSString *)merchantIdentifier merchantSessionIdentifier:(NSString *)merchantSessionIdentifier nonce:(NSString *)nonce epochTimestamp:(NSUInteger)epochTimestamp expiresAt:(NSUInteger)expiresAt displayName:(NSString *)displayName initiativeContext:(NSString *)initiativeContext initiative:(NSString *)initiative ampEnrollmentPinning:(NSData *)ampEnrollmentPinning operationalAnalyticsIdentifier:(NSString *)operationalAnalyticsIdentifier signedFields:(NSArray *)signedFields signature:(NSData *)signature
{
    if (!(self = [self init]))
        return nil;
    wkStoreValue(_values, @"merchantIdentifier", merchantIdentifier);
    wkStoreValue(_values, @"merchantSessionIdentifier", merchantSessionIdentifier);
    wkStoreValue(_values, @"nonce", nonce);
    wkStoreValue(_values, @"epochTimestamp", @(epochTimestamp));
    wkStoreValue(_values, @"expiresAt", @(expiresAt));
    wkStoreValue(_values, @"displayName", displayName);
    wkStoreValue(_values, @"initiativeContext", initiativeContext);
    wkStoreValue(_values, @"initiative", initiative);
    wkStoreValue(_values, @"ampEnrollmentPinning", ampEnrollmentPinning);
    wkStoreValue(_values, @"operationalAnalyticsIdentifier", operationalAnalyticsIdentifier);
    wkStoreValue(_values, @"signedFields", signedFields);
    wkStoreValue(_values, @"signature", signature);
    return self;
}

- (instancetype)initWithMerchantIdentifier:(NSString *)merchantIdentifier merchantSessionIdentifier:(NSString *)merchantSessionIdentifier nonce:(NSString *)nonce epochTimestamp:(NSUInteger)epochTimestamp expiresAt:(NSUInteger)expiresAt domain:(NSString *)domainName displayName:(NSString *)displayName operationalAnalyticsIdentifier:(NSString *)operationalAnalyticsIdentifier signature:(NSData *)signature
{
    if (!(self = [self init]))
        return nil;
    wkStoreValue(_values, @"merchantIdentifier", merchantIdentifier);
    wkStoreValue(_values, @"merchantSessionIdentifier", merchantSessionIdentifier);
    wkStoreValue(_values, @"nonce", nonce);
    wkStoreValue(_values, @"epochTimestamp", @(epochTimestamp));
    wkStoreValue(_values, @"expiresAt", @(expiresAt));
    wkStoreValue(_values, @"domainName", domainName);
    wkStoreValue(_values, @"displayName", displayName);
    wkStoreValue(_values, @"operationalAnalyticsIdentifier", operationalAnalyticsIdentifier);
    wkStoreValue(_values, @"signature", signature);
    return self;
}

- (instancetype)initWithDelegateDisplayName:(NSString *)delegateDisplayName merchantIdentifier:(NSString *)merchantIdentifier displayName:(NSString *)displayName initiative:(NSString *)initiative initiativeContext:(NSString *)initiativeContext merchantSessionIdentifier:(NSString *)merchantSessionIdentifier nonce:(NSString *)nonce epochTimestamp:(NSUInteger)epochTimestamp expiresAt:(NSUInteger)expiresAt operationalAnalyticsIdentifier:(NSString *)operationalAnalyticsIdentifier signedFields:(NSArray *)signedFields signature:(NSData *)signature
{
    if (!(self = [self initWithMerchantIdentifier:merchantIdentifier merchantSessionIdentifier:merchantSessionIdentifier nonce:nonce epochTimestamp:epochTimestamp expiresAt:expiresAt displayName:displayName initiativeContext:initiativeContext initiative:initiative ampEnrollmentPinning:nil operationalAnalyticsIdentifier:operationalAnalyticsIdentifier signedFields:signedFields signature:signature]))
        return nil;
    wkStoreValue(_values, @"isDelegatedSession", @YES);
    wkStoreValue(_values, @"delegateDisplayName", delegateDisplayName);
    return self;
}

- (NSString *)merchantIdentifier { return [_values objectForKey:@"merchantIdentifier"]; }
- (NSString *)merchantSessionIdentifier { return [_values objectForKey:@"merchantSessionIdentifier"]; }
- (NSString *)nonce { return [_values objectForKey:@"nonce"]; }
- (NSString *)domainName { return [_values objectForKey:@"domainName"]; }
- (NSString *)displayName { return [_values objectForKey:@"displayName"]; }
- (NSData *)signature { return [_values objectForKey:@"signature"]; }

@end
WK_PRIV_ALIAS(PKPaymentMerchantSession);
WK_POLYFILL_CLASS(WK_PASSKITCORE, PKPaymentMerchantSession);
