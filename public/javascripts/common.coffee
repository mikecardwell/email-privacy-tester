## Email class

	Email =
		validate: ( email ) ->
			@toASCII(email).match ".+@([a-zA-Z0-9]([-a-zA-Z0-9]*[a-zA-Z0-9])?\\.)*[a-zA-Z]{2,}$"
		validateInput: ( $input, e ) ->
			email = $input.val()
			if email == ''
				$input.removeClass 'bad'
				e.preventDefault() if e
			else if @validate email
				email2 = @toUnicode email
				if email2 != email then $input.val email2
				$input.removeClass 'bad'
			else
				$input.addClass 'bad'
				e.preventDefault() if e?
		
		toUnicode: ( email ) ->
			return email unless email.match /.@./
			local_part = email.replace /(.+)@.+/, '$1'
			domain     = punycode.toUnicode email.replace /.+@/, ''
			return "#{local_part}@#{domain}"

		toASCII: ( email ) ->
			return email unless email.match /.@./
			local_part = email.replace /(.+)@.+/, '$1'
			domain     = punycode.toASCII email.replace /.+@/, ''
			return "#{local_part}@#{domain}"

## Get rid of query params in the address bar

	if history?.replaceState? then history.replaceState {}, $('head > title').text(), document.location.pathname

## Auto focus on the first input field on page load

	if window == top then $(document).ready () -> $('input.text,input.email').select().focus()

## When email fields blur, validate it

	$('.view').on 'blur', 'input.email', (e) -> Email.validateInput $(this)

## Don't allow submission of forms with input.email fields containing bad email addresses

	$('.view').on 'submit', 'form', (e) ->
		$(this).find('input.email').each () -> Email.validateInput $(this), e

## Pre-fetch pages on hover

	#$('body').on 'mouseover', 'a', (e) ->
		#if $(this).data 'prefetch'
			#$(this).data 'prefetch', null
			#href = $(this).attr 'href'
			#$('body').append( $('<iframe class="hidden" sandbox=""/>').attr('src', href) )
			#$.get href if href

## Debug performance code

	if console?.log?
		$(document).ready () ->
			try
				reqStartResStart = window.performance.timing.responseStart - window.performance.timing.requestStart
				console.log "From request start to response start: #{reqStartResStart/1000} seconds"
			catch e
