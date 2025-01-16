package require aws 2
package require tomcrypt 0.6.0
package require Pixel
package require Pixel_jpeg
package require Pixel_webp
package require Pixel_png
package require parse_args
package require rl_json
package require chantricks
package require reuri
package require rl_http
package require sqlite3

interp alias {} ::json			{} ::rl_json::json
interp alias {} ::parse_args	{} ::parse_args::parse_args

tomcrypt::prng create prng {}

namespace eval ::s3 { # API shim for old hand-written s3 module, on top of aws::s3 2
	namespace export *
	namespace ensemble create -prefixes no
	proc get args { #<<<
		parse_args::parse_args $args {
			-bucket				{-required}
			-response_headers	{-alias}
			-region				{-default ""}
			path				{-required}
		}

		if {$region eq ""} {set region af-south-1}

		set path    [join [lmap e [split $path /] {
			string map {/ %2f} [reuri decode $e]
		}] /]

		set res	[aws s3 get_object -region $region -bucket $bucket -key $path -payload bytes]
		set hdrs	{}
		json foreach {k v} $res {
			dict set hdrs [string tolower $k] [list [json get $v]]
		}
		set response_headers	$hdrs
		set bytes
	}

	#>>>
	proc upload args { #<<<
		parse_args::parse_args $args {
			-region				{-default ""}
			-bucket				{-required}
			-path				{-required}
			-data				{-required}
			-content_type		{}
			-max_age			{-default 31536000}
			-acl				{-enum public-read}
			-response_headers	{-alias}
		}

		if {![info exists content_type]} {
			package require Pixel 3.4.3
			try {
				set content_type	[pixel::image_mimetype $data]
			} trap {PIXEL CORE UNKNOWN_FILETYPE} {errmsg options} {
				set content_type	application/octet-stream
			}
		}

		switch -glob -- $content_type {
			text/* -
			application/json -
			application/javascript {
				set data	[encoding convertto utf-8 $data]
			}
		}

		if {$region eq ""} {set region af-south-1}

		if 0 {
		set res	[aws s3 put_object \
			-region			$region \
			-bucket			$bucket \
			-key			$path \
			-content_type	$content_type \
			-cache_control	max-age=$max_age \
			-ACL			$acl \
			-body			$data \
		]

		set hdrs	{}
		json foreach {k v} $res {
			dict set hdrs [string tolower $k] [list [json get $v]]
		}
		set response_headers $hdrs
		} else {
			set headers		[list Cache-Control max-age=$max_age]
			if {[info exists acl]} {
				lappend headers x-amz-acl $acl
			}
			# Hack the upload until the put_object generated proc is working
			# S3 doesn't like + in path elements
			set path	[join [lmap e [split $path /] {
				reuri encode path [reuri decode [string map {+ %2B} $e]]
			}] /]
			::aws::helpers::_aws_req PUT $bucket.s3.$region.amazonaws.com /$path \
				-region						$region \
				-scheme						https \
				-credential_scope			$region \
				-disable_double_encoding	1 \
				-signing_region				$region \
				-expecting_status			200 \
				-headers					$headers \
				-params						{} \
				-content_type				$content_type \
				-body						$data \
				-response_headers			response_headers \
				-status						status \
				-sig_service				s3 \
				-version					s3v4
		}

		return
	}

	#>>>
	proc exists args { #<<<
		parse_args::parse_args $args {
			-region				{-default ""}
			-bucket				{-required}
			-response_headers	{-alias}
			path				{-required}
		}

		if {$region eq ""} {set region af-south-1}
		try {
			# Hack the exists until the head_object generated proc is working
			# S3 doesn't like + in path elements
			set path	[reuri normalize $path]
			set path	[join [lmap e [split $path /] {
				string map {+ %2B} $e
			}] /]
			::aws::helpers::_aws_req HEAD $bucket.s3.$region.amazonaws.com /$path \
				-region						$region \
				-scheme						https \
				-credential_scope			$region \
				-disable_double_encoding	1 \
				-signing_region				$region \
				-expecting_status			200 \
				-response_headers			response_headers \
				-status						status \
				-sig_service				s3 \
				-version					s3v4
		} on ok {} {
			return 1
		} trap {AWS 404} {} - trap {AWS 403} {} {
			return 0
		}
	}

	#>>>
	proc delete args { #<<<
		parse_args::parse_args $args {
			-region		{-default ""}
			-bucket		{-required}
			-path		{-required}
		}

		if {$region eq ""} {set region af-south-1}

		aws s3 delete_object -region $region -bucket $bucket -key $path
	}

	#>>>
	proc ls args { #<<<
		parse_args::parse_args $args {
			-region				{-default {}}
			-prefix				{}
			-bucket				{-required}
			-delimiter			{}
			-max_keys			{-# {Defaults to 1000}}
			-continuation_token	{-default {}}
			-fetch_owner		{-boolean}
			-start_after		{}
			-encoding_type		{-enum url -# {If set to "url", responses are urlencoded (to permit C0 characters)i}}
		}

		set extra	{}
		if {$fetch_owner} {
			lappend extra -fetch_owner
		}
		if {[info exists start_after]} {
			lappend extra -start_after $start_after
		}
		if {[info exists encoding_type]} {
			lappend extra -encoding_type $encoding_type
		}
		if {$continuation_token ne {}} {
			lappend extra -continuation_token $continuation_token
		}
		if {[info exists max_keys]} {
			lappend extra -max_keys $max_keys
		}
		if {[info exists delimiter]} {
			lappend extra -delimiter $delimiter
		}
		if {[info exists prefix]} {
			lappend extra -prefix $prefix
		}
		if {$region eq {}} {
			set region af-south-1
		}

		set resp	[aws s3 list_objects_v2 \
			-region				$region \
			-bucket				$bucket \
			{*}$extra \
		]

		set truncated				[json get $resp IsTruncated]
		set next_continuation_token	[json get -default {} $resp NextContinuationToken]
		set res	[json template {
			{
				"truncated":				"~B:truncated",
				"next_continuation_token":	"~S:next_continuation_token",
				"results":					[]
			}
		}]

		if {[info exists delimiter]} {
			json set res commonprefixes {[]}
		}

		json foreach e [json extract $resp Contents] {
			json set res results end+1 [json template {
				{
					"key":			"~S:Key",
					"mtime":		"~S:LastModified",
					"etag":			"~S:ETag",
					"size":			"~N:Size",
					"storageclass":	"~S:StorageClass"
				}
			} [json get $e]]

			if {$fetch_owner} {
				json set res results end owner [json template {
					{
						"id":			"~S:ID",
						"displayname":	"~S:DisplayName"
					}
				} [json get $e Owner]]
			}
		}

		if {[json exists $resp CommonPrefixes]} {
			json foreach e [json extract $resp CommonPrefixes] {
				json set res commonprefixes end+1 [json get $e Prefix]
			}
		}

		set res
	}

	#>>>
	proc copy args { #<<<
		parse_args::parse_args $args {
			-bucket			{-required}
			-path			{-required}
			-region			{-default ""}
			-source_bucket	{-# {Defaults to -bucket}}
			-source			{-required}
			-max_age		{-default 31536000}
			-acl			{}
		}

		if {![info exists source_bucket]} {
			set source_bucket	$bucket
		}

		if {$region eq ""} {set region af-south-1}
		set extra	{}
		if {[info exists acl]} {
			lappend extra	-ACL $acl
		}

		aws s3 copy_object \
			-region			$region \
			-bucket			$bucket \
			-key			$path \
			-copy_source	$source_bucket/$source \
			-payload		payload \
			{*}$extra

		set payload
	}

	#>>>
}

proc dynamodb_decode_json value { #<<<
	if {
		[json type $value] ne "object" ||
		[json length $value] != 1
	} {error "Not a valid dynamodb value: ($value)"}

	json foreach {k v} $value {
		return [switch -exact -- $k {
			S - SS	{json extract $v}
			N		{json number [json get $v]}
			NS		{json amap sv $v {json number [json get $v]}}
			B		{binary decode base64 [json get $v]}
			BS		{json lmap sv $v {binary decode base64 [json get $sv]}}
			M		{json omap {mk kv} $v {list $mk [dynamodb_decode_json $kv]}}
			L		{json amap sv $v {dynamodb_decode_json $sv}}
			BOOL	{json bool [json get $v]}
			NULL	{return -level 0 null}
			default	{error "Not a valid dynamodb value: ($value)"}
		}]
	}
}

#>>>
proc bucket {} { #<<<
	global _bucket env
	if {![info exists _bucket]} {
		if {[info exists env(BUCKET_NAME)]} {
			set _bucket	$env(BUCKET_NAME)
		} else {
			set _bucket	[json get [aws cloudformation describe_stack_resource -stack_name semantic-content-fs -logical_resource_id Bucket] StackResourceDetail PhysicalResourceId]
		}
	}
	set _bucket
}

#>>>
proc table {} { #<<<
	global _table env
	if {![info exists _table]} {
		if {[info exists env(TABLE_NAME)]} {
			set _table	$env(TABLE_NAME)
		} else {
			set _table	[json get [aws cloudformation describe_stack_resource -stack_name semantic-content-fs -logical_resource_id Table] StackResourceDetail PhysicalResourceId]
		}
	}
	set _table
}

#>>>
proc voyageai_api_key {} { #<<<
	global _voyageai_api_key
	if {![info exists _voyageai_api_key]} {
		set _voyageai_api_key	[json get [aws secretsmanager get_secret_value -secret_id voyageai/test1] SecretString]
	}
	set _voyageai_api_key
}

#>>>
proc semfs_data_key {} { #<<<
	global _semfs_data_key
	if {![info exists _semfs_data_key]} {
		set _semfs_data_key	[string range [binary decode base64 [json get [aws secretsmanager get_secret_value -secret_id semfs/key] SecretString]] 0 55]
	}
	set _semfs_data_key
}

#>>>
proc encrypt_data bytes { #<<<
	set iv	[prng bytes 8]
	string cat $iv [tomcrypt::encrypt {blowfish 448 cbc} [semfs_data_key] $iv $bytes]
}

#>>>
proc decrypt_data ciphertext { #<<<
	binary scan $ciphertext a8a* iv cbytes
	tomcrypt::decrypt {blowfish 448 cbc} [semfs_data_key] $iv $cbytes
}

#>>>
proc load_image bytes { #<<<
	pixel::pmap_to_pmapf [switch -glob -- [pixel::image_mimetype $bytes] {
		image/jpeg	{pixel::jpeg::decodejpeg $bytes}
		image/png	{pixel::png::decode $bytes}
		image/webp	{pixel::webp::decode $bytes}
		image/* {
			pixel::webp::decode [chantricks with_chan h {open {|convert - webp:-} rb+} {
				puts -nonewline $h $bytes
				close $h write
				read $h
			}]
		}
		default {error "Unsupported image type: [pixel::image_mimetype $bytes]"}
	}]
}

#>>>
proc scale args { #<<<
	parse_args $args {
		-type	{-enum {max_edge min_edge width height mpx} -default min_edge}
		-val	{-required}
		-pmapf	{-required}
	}
	lassign [pixel::pmapf_info $pmapf] w h
	set old_w	$w
	set old_h	$h

	if {$w >= $h} {
		set major	w
		set minor	h
	} else {
		set major	h
		set minor	w
	}

	switch -exact -- $type {
		min_edge {
			set $major	[expr {int(round([set $major] * double($val)/[set $minor]))}]
			set $minor	$val
		}
		max_edge {
			set $minor	[expr {int(round([set $minor] * double($val)/[set $major]))}]
			set $major	$val
		}
		width {
			set h	[expr {int(round($h * double($val)/$w))}]
			set w	$val
		}
		height {
			set w	[expr {int(round($w * double($val)/$h))}]
			set h	$val
		}
		mpx {
			set f	[expr {double($val)/($w*$h)}]
			set w	[expr {int(round($w * $f))}]
			set h	[expr {int(round($h * $f))}]
		}
		default {error "Unexpected type \"$type\""}
	}

	if {$w != $old_w || $h != $old_h} {
		set pmapf	[pixel::scale_pmapf_lanczos $pmapf $w $h]
	}
	
	set pmapf
}

#>>>
proc encode args { #<<<
	parse_args $args {
		-q		{-default 83}
		-pmapf	{-required}
	}
	pixel::webp::encode [pixel::pmapf_to_pmap $pmapf] $q
}

#>>>
proc cachepath {} { #<<<
	global env
	set path	[file join $env(HOME) .cache semfs]
	if {![file exists $path]} {
		file mkdir $path
	}
	set path
}

#>>>
proc get args { #<<<
	parse_args $args {
		-edge	{}
		-cached	{-boolean}
		md5b64	{-required}
	}

	if {$cached} {
		set cache_fn	[file join [cachepath] $md5b64]
		if {[file readable $cache_fn]} {
			set bytes	[chantricks readbin $cache_fn]
		} else {
			set bytes	[s3 get -bucket [bucket] -- $md5b64]
			chantricks writebin $cache_fn $bytes
		}
	} else {
		set bytes	[s3 get -bucket [bucket] -- $md5b64]
	}

	set bytes	[decrypt_data $bytes]

	if {[info exists edge]} { # Scale so that the shortest edge is $edge px <<<
		set bytes	[encode -pmapf [scale -pmapf [load_image $bytes] -type min_edge -val $edge]]
	}
	#>>>

	set bytes
}

#>>>
proc embed args { #<<<
	parse_args $args {
		-timeout	{-default 20.0}
		md5b64s		{-required -args all}
	}

	set inputs			{[]}

	foreach md5b64 $md5b64s {
		set bytes			[get -edge 400 -- $md5b64]
		set mimetype		[pixel::image_mimetype $bytes]
		set image_base64	"data:[pixel::image_mimetype $bytes];base64,[binary encode base64 $bytes]"
		puts "inline image for $md5b64: [string length $image_base64]"
		if 0 {
		apply {bytes {
			chantricks with_chan h {file tempfile fn} {
				try {
					chan configure $h -translation binary
					puts -nonewline $h $bytes
					flush $h
					exec feh -Z --scale-down -F -Y $fn
				} finally {
					file delete $fn
				}
			}
		}} $bytes
		}
		json set inputs end+1 content [json template {
			[
				{
					"type":				"image_base64",
					"image_base64":		"~S:image_base64"
				}
			]
		}]
	}

	set resp	[embed_req -timeout $timeout -- [json template {
		{
			"model":		"voyage-multimodal-3",
			"input_type":	"document",
			"inputs":		"~J:inputs"
		}
	}]]

	set res		{{}}
	json foreach r [json extract $resp data] {
		set md5b64	[lindex $md5b64s [json get $r index]]
		json set res $md5b64 [json extract $r embedding]
	}

	set res
}

#>>>
proc embed_req args { #<<<
	parse_args $args {
		-timeout	{-default 10.0}
		req			{-required}
	}

	set horizon		[expr {int([clock microseconds] + $timeout*1e6)}]
	set delay		1
	while 1 {
		set remain	[expr {($horizon-[clock microseconds])/1e6}]
		if {$remain <= 0} {
			throw {RL HTTP TIMEOUT throttled} "Ran out of time while retying 429 failures"
		}

		rl_http instvar h POST https://api.voyageai.com/v1/multimodalembeddings -timeout $remain -headers [list \
			Authorization	"Bearer [voyageai_api_key]" \
			Content-Type	application/json \
		] -data [encoding convertto utf-8 $req]

		switch -glob -- [$h code] {
			2*	{return [$h body]}
			429	{
				after 		[expr {int($delay*1000 + rand()*100)}]
				set delay	[expr {$delay * 2}]
				continue
			}
			default {error "[$h code] [$h body]"}
		}
	}
}

#>>>
proc store_embedding {md5b64 embedding} { #<<<
	set pk			$md5b64
	set sk			embedding

	set packed		[binary encode base64 [binary format r* [json get $embedding]]]	;# single precision little-endian IEEE floats

	if 0 {
	aws dynamodb execute_statement -statement [subst {
		UPSERT INTO "[string map [list "\"" "\"\""] [table]]" VALUE {'pk': ?, 'sk': ?, 'embedding': ?}
	}] -parameters [json template {
		[
			{"S": "~S:pk"},
			{"S": "~S:sk"},
			{"B": "~S:packed"}
		]
	}]
	} else {
		aws dynamodb put_item \
			-table_name		[table] \
			-item [json template {
				{
					"pk":			{"S": "~S:pk"},
					"sk":			{"S": "~S:sk"},
					"embedding":	{"B": "~S:packed"}
				}
			}]
	}
}

#>>>
proc read_embedding md5b64 { #<<<
	set pk		$md5b64
	set sk		embedding
	set res	[aws dynamodb execute_statement -statement [subst {
		select embedding from "[string map [list "\"" "\"\""] [table]]" where pk = ? and sk = ?
	}] -parameters [json template {
		[
			{"S": "~S:pk"},
			{"S": "~S:sk"}
		]
	}]]

	set packed	[dynamodb_decode_json [json extract $res Items 0 embedding]]
	binary scan $packed r* floats
	set embedding	{[]}
	foreach float $floats {
		json set embedding end+1 $float
	}
	set embedding
}

#>>>
proc purge_item md5b64 { #<<<
	set pk	$md5b64
	set sk		embedding

	aws dynamodb execute_statement -statement [subst {
		delete from "[string map [list "\"" "\"\""] [table]]" where pk = ? and sk = ?
	}] -parameters [json template {
		[
			{"S": "~S:pk"},
			{"S": "~S:sk"}
		]
	}]
}

#>>>
proc reindex {} { #<<<
	try {
		sqlite3 db /tmp/semfs.sqlite3
		db enable_load_extension 1
		db eval {select load_extension('./vec0.so')}
		db transaction {
			db eval {
				drop table if exists embeddings;
				create virtual table embeddings using vec0 (
					md5b64		text primary key,
					embedding	float[1024]
				);
			}
			set extra	{}
			while 1 {
				set res	[aws dynamodb scan \
					-table_name						[table] \
					-select							SPECIFIC_ATTRIBUTES \
					-return_consumed_capacity		TOTAL \
					-projection_expression			{pk, embedding} \
					-filter_expression				{sk = :val} \
					-expression_attribute_values	{{":val":{"S":"embedding"}}} \
					{*}$extra \
				]
				#chantricks writefile /tmp/scan_res.json [json pretty $res]

				json foreach ddb_item [json extract $res Items] {
					set item	[json omap {k v} $ddb_item {list $k [dynamodb_decode_json $v]}]
					set md5b64	[json get $item pk]
					binary scan [json get $item embedding] r* floats
					set embedding	{[]}
					foreach float $floats {
						json set embedding end+1 $float
					}
					db eval {insert into embeddings (md5b64, embedding) values (:md5b64, :embedding)}
				}
				puts "inserted [json length $res Items] embeddings"
				if {![json exists $res LastEvaluatedKey]} break
				set extra	[list -exclusive_start_key [json extract $res LastEvaluatedKey]]
				puts "continuing with $extra"
			}
		}
	} finally {
		rename db {}
	}
}

#>>>
proc embed_query str { #<<<
}

#>>>

# vim: foldmethod=marker foldmarker=<<<,>>> ts=4 shiftwidth=4
