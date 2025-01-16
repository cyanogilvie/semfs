set here	[file dirname [file normalize [info script]]]
source [file join $here common.tcl]
package require jsonlog
interp alias {} ::log {} ::jsonlog::log

proc handler {event context} { #<<<
	try {
		set added	{}
		set removed	{}
		set md5b64s	[json lmap record [json extract $event Records] {
			set bucket	[json get $record s3 bucket name]
			set key		[string map {+ { }} [json get $record s3 object key]]
			switch -glob -- [json get $record eventName] {
				ObjectCreated:* {lappend added		$key}
				ObjectRemoved:* {lappend removed	$key}
				default {error "Unexpected event: ([json get $record eventName])"}
			}
		}]

		if {[llength $added]} {
			log notice "[llength $added] md5b64s added: $added"
			set res	[embed -timeout 28 -- {*}$added]
			json foreach {md5b64 embedding} $res {
				store_embedding $md5b64 $embedding
			}
		}

		if {[llength $removed]} {
			log notice "[llength $removed] md5b64s removed: $removed"
			# TODO: Remove from metadata
			log notice "Removing $removed"
			foreach md5b64 $removed {
				purge_item $md5b64
			}
		}
	} on error {errmsg options} {
		log error "Unhandled error [dict get $options -errorcode]: [dict get $options -errorinfo]"
		return -options $options $errmsg
	}
}

#>>>

# vim: foldmethod=marker foldmarker=<<<,>>> ts=4 shiftwidth=4 noexpandtab
