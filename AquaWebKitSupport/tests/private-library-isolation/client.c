extern int fixture_crypto(void);
extern int fixture_ssl(void);
extern int fixture_avcodec(void);

int check_client_libraries(void)
{
    return fixture_crypto() == 101 && fixture_ssl() == 202 && fixture_avcodec() == 303;
}
