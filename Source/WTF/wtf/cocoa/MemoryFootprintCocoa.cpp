/*
 * Copyright (C) 2017 Apple Inc. All rights reserved.
 *
 * Redistribution and use in source and binary forms, with or without
 * modification, are permitted provided that the following conditions
 * are met:
 * 1. Redistributions of source code must retain the above copyright
 *    notice, this list of conditions and the following disclaimer.
 * 2. Redistributions in binary form must reproduce the above copyright
 *    notice, this list of conditions and the following disclaimer in the
 *    documentation and/or other materials provided with the distribution.
 *
 * THIS SOFTWARE IS PROVIDED BY APPLE INC. ``AS IS'' AND ANY
 * EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE
 * IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR
 * PURPOSE ARE DISCLAIMED.  IN NO EVENT SHALL APPLE INC. OR
 * CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL,
 * EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO,
 * PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR
 * PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY
 * OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
 * (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE
 * OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
 */

#include "config.h"
#include <wtf/MemoryFootprint.h>

// MAVERICKS_BACKPORT: offsetof, for the phys_footprint reply-length check below. This build is
// -fno-modules, so the declaration does not arrive transitively the way it does under upstream's
// module-enabled Apple build.
#include <cstddef>
#include <mach/mach.h>
#include <mach/task_info.h>

namespace WTF {

size_t memoryFootprint()
{
    task_vm_info_data_t vmInfo;
    mach_msg_type_number_t count = TASK_VM_INFO_COUNT;
    kern_return_t result = task_info(mach_task_self(), TASK_VM_INFO, (task_info_t) &vmInfo, &count);
    if (result != KERN_SUCCESS)
        return 0;

    // MAVERICKS_BACKPORT: phys_footprint postdates this deployment target. A 10.9 kernel
    // answers TASK_VM_INFO with a structure that ends before that field and reports the
    // length it actually filled in, so read phys_footprint only when the reply reaches it.
    // phys_footprint is the task's internal (dirty anonymous) footprint plus whatever the
    // compressor holds for the task, and 10.9 does return both of those fields. Measured
    // here: internal+compressed is 278528 where TASK_BASIC_INFO resident_size reports
    // 503808, so RSS is not a usable stand-in -- it counts clean file-backed pages that are
    // not part of the footprint, which overstates memory pressure.
    constexpr mach_msg_type_number_t countThroughPhysFootprint = static_cast<mach_msg_type_number_t>(
        (offsetof(task_vm_info_data_t, phys_footprint) + sizeof(vmInfo.phys_footprint)) / sizeof(natural_t));
    if (count >= countThroughPhysFootprint)
        return static_cast<size_t>(vmInfo.phys_footprint);
    return static_cast<size_t>(vmInfo.internal + vmInfo.compressed);
}

}
