/*
 * Copyright (c) 2025 Frederick H. G. Wright II <fw@fwright.net>
 *
 *
 * THIS SOFTWARE IS PROVIDED BY THE AUTHOR AND CONTRIBUTORS ``AS IS'' AND
 * ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE
 * IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE
 * ARE DISCLAIMED.  IN NO EVENT SHALL THE AUTHOR OR CONTRIBUTORS BE LIABLE
 * FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL
 * DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS
 * OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION)
 * HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT
 * LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY
 * OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF
 * SUCH DAMAGE.
 */

/* MP support header */
#include "LegacySupport.h"

/*
 * The pthread_[f]chdir_np() functions are available as syscalls starting
 * in 10.5, but not as functions until 10.12.  This provides the missing
 * function wrappers where needed.
 */

#define _MACPORTS_LEGACY_PTHREAD_CHDIR 1
#include <pthread.h>
#include <unistd.h>

#include <sys/syscall.h>

int
pthread_chdir_np(const char* path)
{
  return syscall(SYS___pthread_chdir, path);
}

int
pthread_fchdir_np(int fd)
{
  return syscall(SYS___pthread_fchdir, fd);
}

/*
 * Provide a per-thread fchdir() for the ATCALL code if possible, but
 * fall back to the (thread-unsafe) process-level version if not (10.4).
 */

#define _MACPORTS_LEGACY_PTHREAD_CHDIR 1
#include <pthread.h>

int
__mpls_best_fchdir(int dirfd)
{
  return pthread_fchdir_np(dirfd);
}

