// Test-only USB double. No access to actual hardware.
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <sys/types.h>
static int mode, started, writes, block_bytes = 4, reads;
static unsigned char opcodes[64];
void mock_reset(int value) { mode=value; started=0; writes=0; reads=0; }
int mock_writes(void) { return writes; }
int mock_opcode(int i) { return opcodes[i]; }
int libusb_init(void **c) { *c=(void *)1; return 0; }
void libusb_exit(void *c) { (void)c; }
ssize_t libusb_get_device_list(void *c, void ***list) {
    (void)c; *list=calloc(2,sizeof(void *)); (*list)[0]=(void *)2; return 1;
}
void libusb_free_device_list(void **l,int unref) { (void)unref; free(l); }
int libusb_get_device_descriptor(void *d,void *desc) {
    (void)d; unsigned char *p=desc; memset(p,0,18);
    p[8]=0x61; p[9]=0x06; p[10]=0; p[11]=0x13; return 0;
}
int libusb_open(void *d, void **handle) { (void)d; *handle=(void *)3; return 0; }
void libusb_close(void *h) { (void)h; }
int libusb_claim_interface(void *h,int i) { (void)h; return i==0?0:-2; }
int libusb_release_interface(void *h,int i) { (void)h;(void)i;return 0; }
const char *libusb_error_name(int code) { (void)code; return "MOCK_USB_ERROR"; }
int libusb_bulk_transfer(void *h,unsigned char ep,unsigned char *p,int n,int *done,unsigned timeout) {
    (void)h;(void)timeout;
    if(ep==2) {
        if(writes>=64) return -2;
        opcodes[writes++]=p[0]; *done=n;
        if(p[0]==4) { if(n!=1)return -2; started=0; }
        else if(p[0]==7) { if(n!=1)return -2; }
        else if(p[0]==1) {
            block_bytes = p[1] == 9 ? 40 : p[1] == 10 ? 20 : p[1] == 11 ? 8 : 4;
            unsigned char expect[8]={1,p[1],1,0,(unsigned char)block_bytes,0,0,0};
            if(n!=8 || memcmp(p,expect,8) || p[1]<9 || p[1]>15) return -2;
        } else if(p[0]==3) {
            unsigned char expect[8]={3,0,0,0,0,0,0,0};
            if(n!=8 || memcmp(p,expect,8)) return -2;
            started=1; if(mode==3){ *done=2;return 0; }
        } else return -2; // Unknown and power-control commands rejected.
        return 0;
    }
    if(ep!=0x81) return -2;
    if(n==64) { *done=0;return -7; }
    if(n!=block_bytes || !started) return -2;
    if(mode==4) { *done=0;return -7; }
    unsigned char bytes[4]={0x78,0x56,0x34,0x92};
    if(mode==2)memset(bytes,0xff,4);
    for (int i=0; i<n/4; ++i) {
        memcpy(p+i*4,bytes,4);
        if(mode==5) { uint32_t value=++reads; memcpy(p+i*4,&value,4); }
        if(mode==6 && i==n/4-1) memset(p+i*4,0xff,4);
    }
    *done=mode==1?2:n; return 0;
}
