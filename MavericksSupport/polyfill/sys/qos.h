#ifndef _SYS_QOS_H_
#define _SYS_QOS_H_

/* QoS classes - introduced in macOS 10.10 */
typedef unsigned int qos_class_t;

#define QOS_CLASS_USER_INTERACTIVE 0x21
#define QOS_CLASS_USER_INITIATED   0x19
#define QOS_CLASS_DEFAULT          0x15
#define QOS_CLASS_UTILITY          0x11
#define QOS_CLASS_BACKGROUND       0x09
#define QOS_CLASS_UNSPECIFIED      0x00

#define QOS_MIN_RELATIVE_PRIORITY (-15)

#endif /* _SYS_QOS_H_ */
