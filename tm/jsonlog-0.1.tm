package require Thread
package require rl_json

tsv::lock jsonlog {
	if {![tsv::exists jsonlog thread_init]} {
		# Thread init script <<<
		tsv::set jsonlog thread_init [string map [list \
			%auto_path%		[list $::auto_path] \
			%tm_path%		[lreverse [tcl::tm::path list]] \
		] {
			set auto_path	%auto_path%
			tcl::tm::path remove {*}[tcl::tm::path list]
			tcl::tm::path add %tm_path%

			package require jsonlog
			namespace import ::jsonlog::log

			interp bgerror {} [list apply {{errmsg options} {
				log error "Background error [dict get $options -errorcode]: [dict get $options -errorinfo]"
			}}]
		}]

		# Thread init script >>>
	}
	if {![tsv::exists jsonlog log_tid]} {
		# Log output thread <<<
		tsv::set jsonlog log_tid [thread::create -preserved {
			eval [tsv::get jsonlog thread_init]
			interp alias {} json {} ::rl_json::json

			set logtail_conns	{}

			proc log_output {thread_name ts jsonmsg} {
				global logtail_conns
				set fracsec	[format .%06d [expr {$ts % 1000000}]]
				json set jsonmsg ts		[clock format [expr {$ts / 1000000}] -format %Y-%m-%dT%H:%M:%S -timezone :UTC]${fracsec}Z
				json set jsonmsg thread	$thread_name
				puts $jsonmsg
				foreach sock $logtail_conns {
					catch {puts $sock $jsonmsg}
				}
			}

			try {
				package require aio 1.7

				proc logtail_conn sock { #<<<
					global logtail_conns
					chan configure $sock -blocking 0 -translation binary -buffering none
					dict set logtail_conns $sock 1
					try {
						while 1 {
							aio waitfor readable $sock
							read $sock
							if {[eof $sock]} break
						}
					} finally {
						dict unset logtail_conns $sock
						if {[info exists sock]} {
							catch {close $sock}
						}
					}
				}

				#>>>
				proc logtail_accept {sock peer_ip peer_port} { #<<<
					coroutine coro_logtail_conn_${peer_ip}:$peer_port logtail_conn $sock
				}

				#>>>

				if {![tsv::get jsonlog logtail_port logtail_port]} {
					set logtail_port	4603
				}
				if {$logtail_port ne ""} {
					set logtail_server	[socket -server logtail_accept $logtail_port]
				}
			} on error {errmsg options} {
				jsonlog log error "Could not start log tail server ([dict get $options -errorcode]): [dict get $options -errorinfo]"
			}

			thread::wait
		}]

		# Log output thread >>>
	}
}

namespace eval ::jsonlog {
	namespace export *
	namespace ensemble create -prefixes no

	namespace path [list {*}[namespace path] {*}{
		::rl_json
	}]

	variable logtemplate {
		{
			"type":	"log",
			"lvl":	"~S:lvl",
			"msg":	"~S:msg"
		}
	}

	variable thread_names	{}

	proc thread_init {} { #<<<
		tsv::get jsonlog thread_init
	}

	#>>>
	proc log_tid {} { #<<<
		variable jsonlog_log_tid
		if {![info exists jsonlog_log_tid]} {
			set jsonlog_log_tid	[tsv::get jsonlog log_tid]
		}
		set jsonlog_log_tid
	}

	#>>>
	proc jsonlog template { #<<<
		set ts	[clock microseconds]
		if {[namespace exists ::ns_shim]} {
			set thread_name	[::ns_shim::interp_name]
		} else {
			set thread_name	[thread_name [thread::id]]
		}
		thread::send -async [log_tid] [list log_output $thread_name $ts [uplevel 1 [list json template $template]]]
	}

	#>>>
	proc log {lvl msg} { #<<<
		variable logtemplate
		jsonlog $logtemplate
	}

	#>>>
	proc thread_name tid { #<<<
		variable thread_names

		if {![dict exists $thread_names $tid]} {
			package require names
			dict set thread_names $tid [names name $tid]
		}
		dict get $thread_names $tid
	}

	#>>>
}

# vim: ft=tcl foldmethod=marker foldmarker=<<<,>>> ts=4 shiftwidth=4
