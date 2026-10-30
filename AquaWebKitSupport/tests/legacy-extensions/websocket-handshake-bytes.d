#pragma D option quiet
#pragma D option strsize=16384

pid$target::*SocketStreamHandleImpl*platformSendInternal*:entry
/arg2 > 4 && arg2 < 16384 && *(uint32_t *)copyin(arg1, 4) == 0x20544547/
{
    printf("HANDSHAKE %d\n%s\nEND_HANDSHAKE\n", arg2, copyinstr(arg1, arg2));
}

pid$target::*WebSocketHandshake*willSendHeaders*:entry
{ printf("INTERCEPT request\n"); }

pid$target::*CocoaCurlSocketStream*receiveWebSocketHandshake*:entry
{ printf("INTERCEPT response\n"); }

BEGIN { printf("READY %d\n", $target); }
