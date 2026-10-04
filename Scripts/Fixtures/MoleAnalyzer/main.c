#define _POSIX_C_SOURCE 200809L
#include <fcntl.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
int main(int argc, char **argv) {
    if(argc != 3 || strcmp(argv[1], "--json")) return 2;
    char path[4096], mode[64] = "success";
    snprintf(path, sizeof(path), "%s/mode", argv[2]);
    FILE *file = fopen(path,"r");
    if(file) { (void)fscanf(file,"%63s",mode); fclose(file); }
    if(!strcmp(mode,"floodout") || !strcmp(mode,"flooderr")) {
        int out = !strcmp(mode,"floodout") ? 1 : 2;
        char bytes[16384]; memset(bytes,'x',sizeof(bytes));
        for(int i=0;i<2048;i++) if(write(out,bytes,sizeof(bytes))<0) return 3;
        return 0;
    }
    if(!strcmp(mode,"flush")) {
        char data[4096]; memset(data,'x',sizeof(data));
        for(int i=0;i<64;i++) if(write(1,data,sizeof(data))<0)return 3;
        return 0;
    }
    if(!strcmp(mode,"orphan-success") || !strcmp(mode,"orphan-failure")) {
        pid_t child=fork();
        if(!child) { for(;;)pause(); }
        snprintf(path,sizeof(path),"%s/child-pid",argv[2]);
        file=fopen(path,"w"); if(!file)return 4;
        fprintf(file,"%d",(int)child); fclose(file);
        return !strcmp(mode,"orphan-success") ? 0 : 9;
    }
    if(!strcmp(mode,"sleep") || !strcmp(mode,"cpu") || !strcmp(mode,"descendant")) {
        if(!strcmp(mode,"descendant")) {
            pid_t child = fork();
            if(!child) { for(;;) pause(); }
            snprintf(path,sizeof(path),"%s/child-pid",argv[2]);
            file=fopen(path,"w"); if(!file)return 4;
            fprintf(file,"%d",(int)child); fclose(file);
        }
        if(!strcmp(mode,"cpu")) { volatile unsigned long long n=0; for(;;) n++; }
        for(;;) pause();
    }
    if(!strcmp(mode,"exit")) return 9;
    if(!strcmp(mode,"invalid")) { puts("not JSON"); return 0; }
    for(int fd=3;fd<256;fd++) if(fcntl(fd,F_GETFD) != -1) return 7;
    if(getenv("MO_ANALYZE_PATH") || getenv("DYLD_INSERT_LIBRARIES") || getenv("MOLE_SOMETHING")) return 5;
    if(strcmp(getenv("PATH"),"/usr/bin:/bin")) return 6;
    printf("{\"scan_status\":\"complete\",\"overview\":false,\"path\":\"%s\",\"entries\":[],\"total_size\":0}\n",argv[2]);
    return 0;
}
