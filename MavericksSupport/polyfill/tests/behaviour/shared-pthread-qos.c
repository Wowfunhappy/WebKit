#include <pthread/qos.h>
#include <assert.h>
#include <errno.h>
#include <stdio.h>
#include <string.h>

int main(void)
{
    pthread_attr_t attr, saved;
    assert(!pthread_attr_init(&attr));
    memcpy(&saved, &attr, sizeof(attr));
    int policyBefore, policyAfter;
    struct sched_param before, after;
    assert(!pthread_getschedparam(pthread_self(), &policyBefore, &before));
    qos_class_t qos = QOS_CLASS_USER_INTERACTIVE;
    int priority = -7;
    errno = EDOM;
    assert(pthread_set_qos_class_self_np(QOS_CLASS_UTILITY, -3) == ENOTSUP);
    assert(pthread_get_qos_class_np(pthread_self(), &qos, &priority) == ENOTSUP);
    assert(pthread_attr_set_qos_class_np(&attr, QOS_CLASS_BACKGROUND, -2) == ENOTSUP);
    assert(pthread_attr_get_qos_class_np(&attr, &qos, &priority) == ENOTSUP);
    assert(errno == EDOM && qos == QOS_CLASS_USER_INTERACTIVE && priority == -7);
    assert(!memcmp(&attr, &saved, sizeof(attr)));
    /* Apple's unsupported-kernel branch precedes argument validation/copyout. */
    assert(pthread_set_qos_class_self_np((qos_class_t)-1, 100) == ENOTSUP);
    assert(pthread_attr_get_qos_class_np((pthread_attr_t *)1, (qos_class_t *)1, (int *)1) == ENOTSUP);
    assert(pthread_attr_set_qos_class_np((pthread_attr_t *)1, (qos_class_t)-1, 100) == ENOTSUP);
    assert(pthread_get_qos_class_np((pthread_t)1, (qos_class_t *)1, (int *)1) == ENOTSUP);
    assert(errno == EDOM);
    assert(!pthread_override_qos_class_start_np(pthread_self(), QOS_CLASS_UTILITY, 0));
    assert(errno == ENOSYS);
    errno = EDOM;
    assert(pthread_override_qos_class_end_np(NULL) == EINVAL && errno == EDOM);
    assert(!pthread_getschedparam(pthread_self(), &policyAfter, &after));
    assert(policyBefore == policyAfter && before.sched_priority == after.sched_priority);
    assert(!pthread_attr_destroy(&attr));
    puts("PASS: unsupported pthread QoS preserves scheduling, attributes, output values and errno");
    return 0;
}
