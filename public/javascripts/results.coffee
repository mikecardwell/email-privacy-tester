## Fade in the status icon

	$('#email_status .status').fadeIn()

## Discover the clock difference between the server and client

	clientTimeDifference = 0
	do () ->
		server_time = $('#system_time').remove().text()
		client_time = window.performance?.timing?.responseStart || new Date().getTime()
		clientTimeDifference = client_time - server_time

## Given a server side time, generate a human readable description of how long ago that was

	humanAge = ( t ) ->
		now  = new Date().getTime() - clientTimeDifference
		sec  = parseInt (now-parseInt(t))/1000
		hour = parseInt sec/3600
		sec -= hour*3600
		min  = parseInt sec/60
		sec -= min*60

		parts = []
		if hour        then parts.push "#{hour} hour#{if hour == 1 then '' else 's'}"
		if hour or min then parts.push "#{min} minute#{if min == 1 then '' else 's'}"
		parts.push "#{sec} second#{if sec==1 then '' else 's'}"

		time = new Date(t).toTimeString().replace /:\d\d .+/,''
	
		return "#{time} - " + parts.join(', ')+' ago'

	minHumanAge = ( t ) ->
		now  = new Date().getTime() - clientTimeDifference
		sec  = parseInt (now-parseInt(t))/1000
		hour = parseInt sec/3600
		sec -= hour * 3600
		min  = parseInt sec/60
		sec -= min * 60
		return if hour then "#{hour}h:#{min}m:#{sec}s" else if min then "#{min}m:#{sec}s" else "#{sec}s"

## Scroll down a bit

	$('html,body').animate { scrollTop: $('#email_status').position().top-10 }, 500

## Wait until the browser tab becomes visible and then immediately execute the function

	runWhenVisible = ( func ) -> func()
	do () ->
		[h,e]=[]
		if document.hidden?
			[h,e] = ['hidden','visibilitychange']
		else if document.mozHidden?
			[h,e] = ['mozHidden','mozvisibilitychange']
		else if document.msHidden?
			[h,e] = ['msHidden','msvisibilitychange']
		else if document.webkitHidden?
			[h,e] = ['webkitHidden','webkitvisibilitychange']
		if h?
			runWhenVisible = ( func ) ->
				return func() unless document[h]
				wrap = () ->
					return if document[h]
					$(document).off e, wrap
					func()
				$(document).on e, wrap

## Detect support for CSS transitions

	hasTransitionSupport = false 
	do () ->
		style = document.createElement('div').style
		for prefix in ['','Webkit','Moz','Ms','O']
			hasTransitionSupport = true if style["#{prefix}Transition"]?

## Email class

	class Email
	
		constructor: ( callback ) ->
			lookup_code = document.location.pathname.replace /.*\//, ''
			[ @_data, @_events ] = [ {}, {} ]

			## Read hidden data from HTML
			@set key, val for key, val of $('#data').data()

			## Update age fields on page every second
	
			do () =>
				timer = () =>
					$('.minHumanAge').each () -> $(this).text minHumanAge $(this).data 'time'
					$('.humanAge').each    () -> $(this).text humanAge    $(this).data 'time'
					setTimeout () ->
						runWhenVisible timer
					, 1000
				timer()
				setTimeout timer, 1000

			unless @get('status')?.status == 'rejected'
				repeat = () =>
					runWhenVisible () =>
						xhr = $.ajax
							url: "#{document.location.pathname}/ajax/#{@get 'emailLogId'}/#{@get 'callbackId'}"
							dataType: 'json'
							async: true
							cache: false
							global: false
							timeout: 35000

						xhr.done ( data ) =>
							if data.emailLogId?  then @set 'emailLogId', data.emailLogId
							if data.callbackId?  then @set 'callbackId', data.callbackId
							if data.emailStatus? then @setEmailStatus data.emailStatus
							if data.hits?        then @newHits data.hits
						
							return if data.emailStatus?.status == 'rejected'
							repeat()

						xhr.fail () -> setTimeout repeat, 1500
				repeat()

		on: ( event, callback ) ->
			event = event.toLowerCase()
			@_events[event] = [] unless @_events[event]?
			@_events[event].push callback

		triggerEvent: ( event, args ) ->
			event = event.toLowerCase()
			if event of @_events
				ev(args) for ev in @_events[event]

		setEmailStatus: ( status ) ->
			@set 'status', status
			@triggerEvent 'emailstatus'
			
		newHits: ( hits ) ->
			@triggerEvent 'newhits', hits

		addUA: ( ua ) ->
			uas = @get 'clientUAs'
			if ua? and ua not in uas
				uas.push ua
				$('#clientUAs').append $('<li/>').text(ua)
				@set 'clientUAs', uas
				$('#testMeta').removeClass 'hidden'

		addIP: ( ip ) ->
			ips = @get 'clientIPs'
			if ip? and ip not in ips
				ips.push ip
				$('#clientIPs').append $('<li/>').text(ip)
				$('#testMeta').removeClass 'hidden'

		test: ( k    ) -> @_data.tests[k]
		get:  ( k    ) -> @_data[k.toLowerCase()]
		set:  ( k, v ) -> @_data[k.toLowerCase()] = v

	email = new Email()

	email.on 'emailstatus', () ->
		status = email.get 'status'
		return unless status?

		unless $('#email_status').hasClass status.status
			$('#email_status').removeClass c for c in ['queued','rejected','sent']
			$('#email_status').addClass status.status
		$('#email_status .status').text status.status
		$('#email_status .message').text status.message
		$('#email_status .mtime').text(humanAge status.mtime).data('time',status.mtime) if status.mtimeAge

	email.on 'newhits', ( tests ) ->
		$testHits = $ '#testHits'

		for name in ( x for x of tests ).reverse()
			hits = tests[name]
			info = email.test name

			## Parse out the IPs and http headers etc
			for hit in hits
				email.addUA hit.httpUserAgent
				email.addIP hit.clientIP
				email.addIP ip for ip in hit.httpXForwardedFor||[]

			container = $("#test_#{name}")
			if container.size() and not container.hasClass 'nohit'
				container.remove().addClass 'flash'
				container.find('span').text(hits[0].ctimeAge).data('time',hits[0].ctime)
				$testHits.prepend container, ' '
			else
				container.remove()
				container = $('<div/>').addClass 'flash'
				container.attr( id: "test_#{name}" )
				anchor = $('<a/>').attr('href',"test/#{name}").text( info.shortDesc )
				anchor.append $('<br/>')
				anchor.append $('<span/>').text(hits[0].ctimeAge).data('time',hits[0].ctime).addClass 'minHumanAge'
				container.append anchor
				$testHits.prepend container, ' '

		setTimeout () ->
			for name of tests
				$("#test_#{name}").removeClass 'flash'
		, if hasTransitionSupport then 1 else 300
