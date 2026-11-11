// Contacts: the value classes WebKit's PassKit types carry, from a framework 10.9 does not ship at all.
// Every class here is registered with WK_POLYFILL_CLASS, so PAL's Contacts soft link resolves them and
// the dlopen of the framework path is answered with the layer's absent-provider token; the key
// constants are in c/Contacts.m.
//
// A contact here is a value object: whatever its creator sets, it carries, copies and archives whole.
// A CNContact made by -init or CNMutableContact holds every key, so -isKeyAvailable: answers YES for
// each key Contacts defines.
#import "wk_priv_class.h"
#import <Foundation/Foundation.h>

typedef NS_ENUM(NSInteger, CNContactType) {
    CNContactTypePerson,
    CNContactTypeOrganization,
};

static NSSet *wkContactKeys(void)
{
    static NSSet *keys;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        keys = [[NSSet alloc] initWithObjects:@"identifier", @"contactType", @"namePrefix", @"givenName", @"middleName",
            @"familyName", @"previousFamilyName", @"nameSuffix", @"nickname", @"organizationName", @"departmentName",
            @"jobTitle", @"phoneticGivenName", @"phoneticMiddleName", @"phoneticFamilyName",
            @"phoneticOrganizationName", @"note", @"birthday", @"nonGregorianBirthday", @"dates", @"phoneNumbers",
            @"emailAddresses", @"postalAddresses", @"urlAddresses", nil];
    });
    return keys;
}

static NSSet *wkContactValueClasses(void)
{
    static NSSet *classes;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        classes = [[NSSet alloc] initWithObjects:[NSString class], [NSNumber class], [NSDateComponents class], [NSArray class], nil];
    });
    return classes;
}

// Sets or, for nil, removes; a copyable value is copied, as the copy properties of the real classes do.
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

#pragma mark - CNPhoneNumber

WK_PRIV_CLASS(CNPhoneNumber) @interface CNPhoneNumber : NSObject <NSCopying, NSSecureCoding> {
    NSString *_digits;
    NSString *_countryCode;
}
+ (instancetype)phoneNumberWithStringValue:(NSString *)stringValue;
+ (instancetype)phoneNumberWithDigits:(NSString *)digits countryCode:(NSString *)countryCode;
- (instancetype)initWithStringValue:(NSString *)stringValue;
@property (nonatomic, readonly) NSString *stringValue;
@property (nonatomic, readonly) NSString *digits;
@property (nonatomic, readonly) NSString *countryCode;
@end

@implementation CNPhoneNumber

+ (BOOL)supportsSecureCoding
{
    return YES;
}

+ (instancetype)phoneNumberWithStringValue:(NSString *)stringValue
{
    return [[[self alloc] initWithStringValue:stringValue] autorelease];
}

+ (instancetype)phoneNumberWithDigits:(NSString *)digits countryCode:(NSString *)countryCode
{
    CNPhoneNumber *number = [[[self alloc] initWithStringValue:digits] autorelease];
    number->_countryCode = [countryCode copy];
    return number;
}

- (instancetype)init
{
    return [self initWithStringValue:@""];
}

- (instancetype)initWithStringValue:(NSString *)stringValue
{
    if (!(self = [super init]))
        return nil;
    _digits = [(stringValue ?: @"") copy];
    return self;
}

- (void)dealloc
{
    [_digits release];
    [_countryCode release];
    [super dealloc];
}

- (NSString *)stringValue
{
    return _digits;
}

- (NSString *)digits
{
    return _digits;
}

- (NSString *)countryCode
{
    return _countryCode;
}

- (id)copyWithZone:(NSZone *)zone
{
    return [self retain];
}

- (instancetype)initWithCoder:(NSCoder *)coder
{
    if (!(self = [self initWithStringValue:[coder decodeObjectOfClass:[NSString class] forKey:@"digits"]]))
        return nil;
    _countryCode = [[coder decodeObjectOfClass:[NSString class] forKey:@"countryCode"] copy];
    return self;
}

- (void)encodeWithCoder:(NSCoder *)coder
{
    [coder encodeObject:_digits forKey:@"digits"];
    [coder encodeObject:_countryCode forKey:@"countryCode"];
}

- (BOOL)isEqual:(id)other
{
    if (![other isKindOfClass:[CNPhoneNumber class]])
        return NO;
    CNPhoneNumber *number = other;
    return [_digits isEqualToString:number->_digits] && (_countryCode == number->_countryCode || [_countryCode isEqual:number->_countryCode]);
}

- (NSUInteger)hash
{
    return [_digits hash];
}

@end
WK_PRIV_ALIAS(CNPhoneNumber);
WK_POLYFILL_CLASS("Contacts", CNPhoneNumber);

#pragma mark - CNPostalAddress

static NSArray *wkPostalAddressKeys(void)
{
    static NSArray *keys;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        keys = [[NSArray alloc] initWithObjects:@"street", @"subLocality", @"city", @"subAdministrativeArea", @"state",
            @"postalCode", @"country", @"ISOCountryCode", @"formattedAddress", nil];
    });
    return keys;
}

WK_PRIV_CLASS(CNPostalAddress) @interface CNPostalAddress : NSObject <NSCopying, NSMutableCopying, NSSecureCoding> {
@protected
    NSMutableDictionary *_values;
}
@property (nonatomic, readonly, copy) NSString *street;
@property (nonatomic, readonly, copy) NSString *subLocality;
@property (nonatomic, readonly, copy) NSString *city;
@property (nonatomic, readonly, copy) NSString *subAdministrativeArea;
@property (nonatomic, readonly, copy) NSString *state;
@property (nonatomic, readonly, copy) NSString *postalCode;
@property (nonatomic, readonly, copy) NSString *country;
@property (nonatomic, readonly, copy) NSString *ISOCountryCode;
@property (nonatomic, readonly, copy) NSString *formattedAddress;
@end

WK_PRIV_CLASS(CNMutablePostalAddress) @interface CNMutablePostalAddress : CNPostalAddress
@property (nonatomic, copy) NSString *street;
@property (nonatomic, copy) NSString *subLocality;
@property (nonatomic, copy) NSString *city;
@property (nonatomic, copy) NSString *subAdministrativeArea;
@property (nonatomic, copy) NSString *state;
@property (nonatomic, copy) NSString *postalCode;
@property (nonatomic, copy) NSString *country;
@property (nonatomic, copy) NSString *ISOCountryCode;
@property (nonatomic, copy) NSString *formattedAddress;
@end

@implementation CNPostalAddress

+ (BOOL)supportsSecureCoding
{
    return YES;
}

- (instancetype)init
{
    if (!(self = [super init]))
        return nil;
    _values = [[NSMutableDictionary alloc] init];
    return self;
}

- (void)dealloc
{
    [_values release];
    [super dealloc];
}

// Every postal property reads as the empty string until set, as Contacts' own do.
- (NSString *)wk_stringForKey:(NSString *)key
{
    return [_values objectForKey:key] ?: @"";
}

- (NSString *)street { return [self wk_stringForKey:@"street"]; }
- (NSString *)subLocality { return [self wk_stringForKey:@"subLocality"]; }
- (NSString *)city { return [self wk_stringForKey:@"city"]; }
- (NSString *)subAdministrativeArea { return [self wk_stringForKey:@"subAdministrativeArea"]; }
- (NSString *)state { return [self wk_stringForKey:@"state"]; }
- (NSString *)postalCode { return [self wk_stringForKey:@"postalCode"]; }
- (NSString *)country { return [self wk_stringForKey:@"country"]; }
- (NSString *)ISOCountryCode { return [self wk_stringForKey:@"ISOCountryCode"]; }
- (NSString *)formattedAddress { return [_values objectForKey:@"formattedAddress"]; }

- (id)wk_copyAsClass:(Class)cls zone:(NSZone *)zone
{
    CNPostalAddress *copy = [[cls allocWithZone:zone] init];
    [copy->_values setDictionary:_values];
    return copy;
}

- (id)copyWithZone:(NSZone *)zone
{
    return [self wk_copyAsClass:[CNPostalAddress class] zone:zone];
}

- (id)mutableCopyWithZone:(NSZone *)zone
{
    return [self wk_copyAsClass:[CNMutablePostalAddress class] zone:zone];
}

- (instancetype)initWithCoder:(NSCoder *)coder
{
    if (!(self = [self init]))
        return nil;
    for (NSString *key in wkPostalAddressKeys()) {
        wkStoreValue(_values, key, [coder decodeObjectOfClass:[NSString class] forKey:key]);
    }
    return self;
}

- (void)encodeWithCoder:(NSCoder *)coder
{
    for (NSString *key in wkPostalAddressKeys())
        [coder encodeObject:[_values objectForKey:key] forKey:key];
}

- (BOOL)isEqual:(id)other
{
    return [other isKindOfClass:[CNPostalAddress class]] && [_values isEqualToDictionary:((CNPostalAddress *)other)->_values];
}

- (NSUInteger)hash
{
    return [_values count];
}

@end
WK_PRIV_ALIAS(CNPostalAddress);
WK_POLYFILL_CLASS("Contacts", CNPostalAddress);


@implementation CNMutablePostalAddress
@dynamic street, subLocality, city, subAdministrativeArea, state, postalCode, country, ISOCountryCode, formattedAddress;

- (void)setStreet:(NSString *)value { wkStoreValue(_values, @"street", value); }
- (void)setSubLocality:(NSString *)value { wkStoreValue(_values, @"subLocality", value); }
- (void)setCity:(NSString *)value { wkStoreValue(_values, @"city", value); }
- (void)setSubAdministrativeArea:(NSString *)value { wkStoreValue(_values, @"subAdministrativeArea", value); }
- (void)setState:(NSString *)value { wkStoreValue(_values, @"state", value); }
- (void)setPostalCode:(NSString *)value { wkStoreValue(_values, @"postalCode", value); }
- (void)setCountry:(NSString *)value { wkStoreValue(_values, @"country", value); }
- (void)setISOCountryCode:(NSString *)value { wkStoreValue(_values, @"ISOCountryCode", value); }
- (void)setFormattedAddress:(NSString *)value { wkStoreValue(_values, @"formattedAddress", value); }

@end
WK_PRIV_ALIAS(CNMutablePostalAddress);
WK_POLYFILL_CLASS("Contacts", CNMutablePostalAddress);

#pragma mark - CNLabeledValue

WK_PRIV_CLASS(CNLabeledValue) @interface CNLabeledValue : NSObject <NSCopying, NSSecureCoding> {
    NSString *_identifier;
    NSString *_label;
    id _value;
}
+ (instancetype)labeledValueWithLabel:(NSString *)label value:(id)value;
- (instancetype)initWithLabel:(NSString *)label value:(id)value;
- (instancetype)initWithIdentifier:(NSString *)identifier label:(NSString *)label value:(id)value;
@property (readonly, copy) NSString *identifier;
@property (readonly, copy) NSString *label;
@property (readonly, copy) id value;
@end

@implementation CNLabeledValue

+ (BOOL)supportsSecureCoding
{
    return YES;
}

+ (instancetype)labeledValueWithLabel:(NSString *)label value:(id)value
{
    return [[[self alloc] initWithLabel:label value:value] autorelease];
}

- (instancetype)initWithLabel:(NSString *)label value:(id)value
{
    return [self initWithIdentifier:[[NSUUID UUID] UUIDString] label:label value:value];
}

- (instancetype)initWithIdentifier:(NSString *)identifier label:(NSString *)label value:(id)value
{
    if (!(self = [super init]))
        return nil;
    _identifier = [(identifier ?: [[NSUUID UUID] UUIDString]) copy];
    _label = [label copy];
    _value = [value copy];
    return self;
}

- (void)dealloc
{
    [_identifier release];
    [_label release];
    [_value release];
    [super dealloc];
}

- (NSString *)identifier { return _identifier; }
- (NSString *)label { return _label; }
- (id)value { return _value; }

- (id)copyWithZone:(NSZone *)zone
{
    return [self retain];
}

- (instancetype)initWithCoder:(NSCoder *)coder
{
    NSSet *valueClasses = [NSSet setWithObjects:[NSString class], [NSDateComponents class], [CNPhoneNumber class], [CNPostalAddress class], nil];
    return [self initWithIdentifier:[coder decodeObjectOfClass:[NSString class] forKey:@"identifier"]
        label:[coder decodeObjectOfClass:[NSString class] forKey:@"label"]
        value:[coder decodeObjectOfClasses:valueClasses forKey:@"value"]];
}

- (void)encodeWithCoder:(NSCoder *)coder
{
    [coder encodeObject:_identifier forKey:@"identifier"];
    [coder encodeObject:_label forKey:@"label"];
    [coder encodeObject:_value forKey:@"value"];
}

- (BOOL)isEqual:(id)other
{
    if (![other isKindOfClass:[CNLabeledValue class]])
        return NO;
    CNLabeledValue *labeled = other;
    return [_identifier isEqualToString:labeled->_identifier] && (_label == labeled->_label || [_label isEqualToString:labeled->_label])
        && (_value == labeled->_value || [_value isEqual:labeled->_value]);
}

- (NSUInteger)hash
{
    return [_identifier hash];
}

@end
WK_PRIV_ALIAS(CNLabeledValue);
WK_POLYFILL_CLASS("Contacts", CNLabeledValue);

#pragma mark - CNContact

WK_PRIV_CLASS(CNContact) @interface CNContact : NSObject <NSCopying, NSMutableCopying, NSSecureCoding> {
@protected
    NSMutableDictionary *_values;
}
- (instancetype)initWithIdentifier:(NSString *)identifier;
- (BOOL)isKeyAvailable:(NSString *)key;
- (BOOL)areKeysAvailable:(NSArray *)keyDescriptors;
@property (readonly, copy) NSString *identifier;
@property (readonly) CNContactType contactType;
@property (readonly, copy) NSString *namePrefix;
@property (readonly, copy) NSString *givenName;
@property (readonly, copy) NSString *middleName;
@property (readonly, copy) NSString *familyName;
@property (readonly, copy) NSString *previousFamilyName;
@property (readonly, copy) NSString *nameSuffix;
@property (readonly, copy) NSString *nickname;
@property (readonly, copy) NSString *organizationName;
@property (readonly, copy) NSString *departmentName;
@property (readonly, copy) NSString *jobTitle;
@property (readonly, copy) NSString *phoneticGivenName;
@property (readonly, copy) NSString *phoneticMiddleName;
@property (readonly, copy) NSString *phoneticFamilyName;
@property (readonly, copy) NSString *phoneticOrganizationName;
@property (readonly, copy) NSString *note;
@property (readonly, copy) NSDateComponents *birthday;
@property (readonly, copy) NSDateComponents *nonGregorianBirthday;
@property (readonly, copy) NSArray *dates;
@property (readonly, copy) NSArray *phoneNumbers;
@property (readonly, copy) NSArray *emailAddresses;
@property (readonly, copy) NSArray *postalAddresses;
@property (readonly, copy) NSArray *urlAddresses;
@end

WK_PRIV_CLASS(CNMutableContact) @interface CNMutableContact : CNContact
@property CNContactType contactType;
@property (copy) NSString *namePrefix;
@property (copy) NSString *givenName;
@property (copy) NSString *middleName;
@property (copy) NSString *familyName;
@property (copy) NSString *previousFamilyName;
@property (copy) NSString *nameSuffix;
@property (copy) NSString *nickname;
@property (copy) NSString *organizationName;
@property (copy) NSString *departmentName;
@property (copy) NSString *jobTitle;
@property (copy) NSString *phoneticGivenName;
@property (copy) NSString *phoneticMiddleName;
@property (copy) NSString *phoneticFamilyName;
@property (copy) NSString *phoneticOrganizationName;
@property (copy) NSString *note;
@property (copy) NSDateComponents *birthday;
@property (copy) NSDateComponents *nonGregorianBirthday;
@property (copy) NSArray *dates;
@property (copy) NSArray *phoneNumbers;
@property (copy) NSArray *emailAddresses;
@property (copy) NSArray *postalAddresses;
@property (copy) NSArray *urlAddresses;
@end

@implementation CNContact

+ (BOOL)supportsSecureCoding
{
    return YES;
}

- (instancetype)init
{
    return [self initWithIdentifier:nil];
}

- (instancetype)initWithIdentifier:(NSString *)identifier
{
    if (!(self = [super init]))
        return nil;
    _values = [[NSMutableDictionary alloc] init];
    wkStoreValue(_values, @"identifier", identifier ?: [[NSUUID UUID] UUIDString]);
    return self;
}

- (void)dealloc
{
    [_values release];
    [super dealloc];
}

- (BOOL)isKeyAvailable:(NSString *)key
{
    return [wkContactKeys() containsObject:key];
}

- (BOOL)areKeysAvailable:(NSArray *)keyDescriptors
{
    for (id key in keyDescriptors) {
        if (![key isKindOfClass:[NSString class]] || ![self isKeyAvailable:key])
            return NO;
    }
    return YES;
}

// String properties read as the empty string until set, and array properties as the empty array.
- (NSString *)wk_stringForKey:(NSString *)key
{
    return [_values objectForKey:key] ?: @"";
}

- (NSArray *)wk_arrayForKey:(NSString *)key
{
    return [_values objectForKey:key] ?: @[];
}

- (NSString *)identifier { return [_values objectForKey:@"identifier"]; }
- (CNContactType)contactType { return (CNContactType)[[_values objectForKey:@"contactType"] integerValue]; }
- (NSString *)namePrefix { return [self wk_stringForKey:@"namePrefix"]; }
- (NSString *)givenName { return [self wk_stringForKey:@"givenName"]; }
- (NSString *)middleName { return [self wk_stringForKey:@"middleName"]; }
- (NSString *)familyName { return [self wk_stringForKey:@"familyName"]; }
- (NSString *)previousFamilyName { return [self wk_stringForKey:@"previousFamilyName"]; }
- (NSString *)nameSuffix { return [self wk_stringForKey:@"nameSuffix"]; }
- (NSString *)nickname { return [self wk_stringForKey:@"nickname"]; }
- (NSString *)organizationName { return [self wk_stringForKey:@"organizationName"]; }
- (NSString *)departmentName { return [self wk_stringForKey:@"departmentName"]; }
- (NSString *)jobTitle { return [self wk_stringForKey:@"jobTitle"]; }
- (NSString *)phoneticGivenName { return [self wk_stringForKey:@"phoneticGivenName"]; }
- (NSString *)phoneticMiddleName { return [self wk_stringForKey:@"phoneticMiddleName"]; }
- (NSString *)phoneticFamilyName { return [self wk_stringForKey:@"phoneticFamilyName"]; }
- (NSString *)phoneticOrganizationName { return [self wk_stringForKey:@"phoneticOrganizationName"]; }
- (NSString *)note { return [self wk_stringForKey:@"note"]; }
- (NSDateComponents *)birthday { return [_values objectForKey:@"birthday"]; }
- (NSDateComponents *)nonGregorianBirthday { return [_values objectForKey:@"nonGregorianBirthday"]; }
- (NSArray *)dates { return [self wk_arrayForKey:@"dates"]; }
- (NSArray *)phoneNumbers { return [self wk_arrayForKey:@"phoneNumbers"]; }
- (NSArray *)emailAddresses { return [self wk_arrayForKey:@"emailAddresses"]; }
- (NSArray *)postalAddresses { return [self wk_arrayForKey:@"postalAddresses"]; }
- (NSArray *)urlAddresses { return [self wk_arrayForKey:@"urlAddresses"]; }

- (id)wk_copyAsClass:(Class)cls zone:(NSZone *)zone
{
    CNContact *copy = [[cls allocWithZone:zone] initWithIdentifier:[self identifier]];
    [copy->_values setDictionary:_values];
    return copy;
}

- (id)copyWithZone:(NSZone *)zone
{
    return [self wk_copyAsClass:[CNContact class] zone:zone];
}

- (id)mutableCopyWithZone:(NSZone *)zone
{
    return [self wk_copyAsClass:[CNMutableContact class] zone:zone];
}

- (instancetype)initWithCoder:(NSCoder *)coder
{
    if (!(self = [self initWithIdentifier:[coder decodeObjectOfClass:[NSString class] forKey:@"identifier"]]))
        return nil;
    NSMutableSet *classes = [NSMutableSet setWithSet:wkContactValueClasses()];
    [classes addObject:[CNLabeledValue class]];
    for (NSString *key in wkContactKeys()) {
        if ([key isEqualToString:@"identifier"])
            continue;
        wkStoreValue(_values, key, [coder decodeObjectOfClasses:classes forKey:key]);
    }
    return self;
}

- (void)encodeWithCoder:(NSCoder *)coder
{
    for (NSString *key in wkContactKeys())
        [coder encodeObject:[_values objectForKey:key] forKey:key];
}

- (BOOL)isEqual:(id)other
{
    return [other isKindOfClass:[CNContact class]] && [_values isEqualToDictionary:((CNContact *)other)->_values];
}

- (NSUInteger)hash
{
    return [[self identifier] hash];
}

@end
WK_PRIV_ALIAS(CNContact);
WK_POLYFILL_CLASS("Contacts", CNContact);


@implementation CNMutableContact
@dynamic contactType, namePrefix, givenName, middleName, familyName, previousFamilyName, nameSuffix, nickname,
    organizationName, departmentName, jobTitle, phoneticGivenName, phoneticMiddleName, phoneticFamilyName,
    phoneticOrganizationName, note, birthday, nonGregorianBirthday, dates, phoneNumbers, emailAddresses,
    postalAddresses, urlAddresses;

- (void)setContactType:(CNContactType)value { wkStoreValue(_values, @"contactType", @(value)); }
- (void)setNamePrefix:(NSString *)value { wkStoreValue(_values, @"namePrefix", value); }
- (void)setGivenName:(NSString *)value { wkStoreValue(_values, @"givenName", value); }
- (void)setMiddleName:(NSString *)value { wkStoreValue(_values, @"middleName", value); }
- (void)setFamilyName:(NSString *)value { wkStoreValue(_values, @"familyName", value); }
- (void)setPreviousFamilyName:(NSString *)value { wkStoreValue(_values, @"previousFamilyName", value); }
- (void)setNameSuffix:(NSString *)value { wkStoreValue(_values, @"nameSuffix", value); }
- (void)setNickname:(NSString *)value { wkStoreValue(_values, @"nickname", value); }
- (void)setOrganizationName:(NSString *)value { wkStoreValue(_values, @"organizationName", value); }
- (void)setDepartmentName:(NSString *)value { wkStoreValue(_values, @"departmentName", value); }
- (void)setJobTitle:(NSString *)value { wkStoreValue(_values, @"jobTitle", value); }
- (void)setPhoneticGivenName:(NSString *)value { wkStoreValue(_values, @"phoneticGivenName", value); }
- (void)setPhoneticMiddleName:(NSString *)value { wkStoreValue(_values, @"phoneticMiddleName", value); }
- (void)setPhoneticFamilyName:(NSString *)value { wkStoreValue(_values, @"phoneticFamilyName", value); }
- (void)setPhoneticOrganizationName:(NSString *)value { wkStoreValue(_values, @"phoneticOrganizationName", value); }
- (void)setNote:(NSString *)value { wkStoreValue(_values, @"note", value); }
- (void)setBirthday:(NSDateComponents *)value { wkStoreValue(_values, @"birthday", value); }
- (void)setNonGregorianBirthday:(NSDateComponents *)value { wkStoreValue(_values, @"nonGregorianBirthday", value); }
- (void)setDates:(NSArray *)value { wkStoreValue(_values, @"dates", value); }
- (void)setPhoneNumbers:(NSArray *)value { wkStoreValue(_values, @"phoneNumbers", value); }
- (void)setEmailAddresses:(NSArray *)value { wkStoreValue(_values, @"emailAddresses", value); }
- (void)setPostalAddresses:(NSArray *)value { wkStoreValue(_values, @"postalAddresses", value); }
- (void)setUrlAddresses:(NSArray *)value { wkStoreValue(_values, @"urlAddresses", value); }

@end
WK_PRIV_ALIAS(CNMutableContact);
WK_POLYFILL_CLASS("Contacts", CNMutableContact);
