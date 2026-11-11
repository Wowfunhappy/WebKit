// Contacts: the CNContact key constants WebKit reaches through PAL's Contacts soft link, from a framework
// 10.9 does not ship at all. Each key's value is the name of the CNContact property it names, as in
// Contacts.framework, and is the key the stub classes in classes/Contacts.m store that property under.
#include "wk_polyfill.h"

#import <Foundation/Foundation.h>

typedef NSString *PolyNSStringConst;

WK_POLYFILL_CONST("Contacts", PolyNSStringConst, CNContactNamePrefixKey, @"namePrefix");
WK_POLYFILL_CONST("Contacts", PolyNSStringConst, CNContactGivenNameKey, @"givenName");
WK_POLYFILL_CONST("Contacts", PolyNSStringConst, CNContactMiddleNameKey, @"middleName");
WK_POLYFILL_CONST("Contacts", PolyNSStringConst, CNContactFamilyNameKey, @"familyName");
WK_POLYFILL_CONST("Contacts", PolyNSStringConst, CNContactPreviousFamilyNameKey, @"previousFamilyName");
WK_POLYFILL_CONST("Contacts", PolyNSStringConst, CNContactNameSuffixKey, @"nameSuffix");
WK_POLYFILL_CONST("Contacts", PolyNSStringConst, CNContactNicknameKey, @"nickname");
WK_POLYFILL_CONST("Contacts", PolyNSStringConst, CNContactOrganizationNameKey, @"organizationName");
WK_POLYFILL_CONST("Contacts", PolyNSStringConst, CNContactDepartmentNameKey, @"departmentName");
WK_POLYFILL_CONST("Contacts", PolyNSStringConst, CNContactJobTitleKey, @"jobTitle");
WK_POLYFILL_CONST("Contacts", PolyNSStringConst, CNContactPhoneticGivenNameKey, @"phoneticGivenName");
WK_POLYFILL_CONST("Contacts", PolyNSStringConst, CNContactPhoneticMiddleNameKey, @"phoneticMiddleName");
WK_POLYFILL_CONST("Contacts", PolyNSStringConst, CNContactPhoneticFamilyNameKey, @"phoneticFamilyName");
WK_POLYFILL_CONST("Contacts", PolyNSStringConst, CNContactPhoneticOrganizationNameKey, @"phoneticOrganizationName");
WK_POLYFILL_CONST("Contacts", PolyNSStringConst, CNContactNoteKey, @"note");
WK_POLYFILL_CONST("Contacts", PolyNSStringConst, CNContactBirthdayKey, @"birthday");
WK_POLYFILL_CONST("Contacts", PolyNSStringConst, CNContactNonGregorianBirthdayKey, @"nonGregorianBirthday");
WK_POLYFILL_CONST("Contacts", PolyNSStringConst, CNContactDatesKey, @"dates");
WK_POLYFILL_CONST("Contacts", PolyNSStringConst, CNContactPhoneNumbersKey, @"phoneNumbers");
WK_POLYFILL_CONST("Contacts", PolyNSStringConst, CNContactEmailAddressesKey, @"emailAddresses");
WK_POLYFILL_CONST("Contacts", PolyNSStringConst, CNContactPostalAddressesKey, @"postalAddresses");
WK_POLYFILL_CONST("Contacts", PolyNSStringConst, CNContactUrlAddressesKey, @"urlAddresses");
