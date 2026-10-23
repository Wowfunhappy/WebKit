#pragma D option quiet

BEGIN
{
    started = timestamp;
}

pid$target:AudioToolbox:*AQMEIO_HAL*_IOProc*:entry
{
    self->output = arg4;
}

pid$target:AudioToolbox:*AQMEIO_HAL*_IOProc*:return
/self->output && arg1 == 0/
{
    this->list = (uint64_t*)copyin(self->output, 24);
    this->data = this->list[2];
    this->size = (this->list[1] >> 32);
    @renders = count();
}

pid$target:AudioToolbox:*AQMEIO_HAL*_IOProc*:return
/self->output && arg1 == 0 && this->data && this->size >= 32/
{
    this->samples = (uint64_t*)copyin(this->data, 32);
    @nonzero = sum(((this->samples[0] | this->samples[1] | this->samples[2] | this->samples[3]) & 0x7fffffff7fffffff) != 0);
}

pid$target:AudioToolbox:*AQMEIO_HAL*_IOProc*:return
{
    self->output = 0;
}

tick-5s
{
    printa("AUDIO renders=%@d nonzero=%@d\n", @renders, @nonzero);
    clear(@renders);
    clear(@nonzero);
}

tick-1s
/timestamp - started >= $1 * 1000000000/
{
    exit(0);
}
