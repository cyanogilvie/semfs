FROM cyanogilvie/alpine-tcl:v0.9.109-stripped

WORKDIR	/var/task
COPY common.tcl ./
COPY onimport.tcl ./
COPY tm/*.tm /usr/local/lib/tcl8/site-tcl/
ENTRYPOINT ["awslambdaric"]
