## Dependencies

  util  = require 'util'
  mysql = require 'mysql'
  conf  = require "#{__dirname}/../conf/main.conf"
  tests = require 'ept/tests'

  emitter = new (require('events').EventEmitter)()
  emitter.setMaxListeners 100

## Connect to the DB

  dbh = mysql.createConnection conf.db

  exports.foo = ( req, res ) ->
    lookupCode = req.params.lookupCode
    res.set 'Content-Type', 'text/plain'
    counter = 0
    setInterval () ->
      res.write "#{++counter}\n"
      res.write util.inspect res, true, null
    , 1000
    for e in [ 'clientError', 'error', 'connect' ]
      do () ->
        event = e
        req.on event, () -> console.log "req: #{event}"
        res.on event, () -> console.log "res: #{event}"

## Test callbacks

  exports.testCallback = ( req, res ) ->

    ## Parse args
    clientIP     = req.socket?.remoteAddress
    callbackCode = req.params.callbackCode
    name         = req.params.name

    return unless clientIP

    [ countDown, email, type ] = [ 2, null, null ]

    onSuccess = () ->
      if type == 'http'
        testCallbackHTTP req, res, email, callbackCode, name, clientIP
      else if type == 'email'
        testCallbackEmail req, res, email, callbackCode, name
      else if type == 'dns'
        testCallbackDNS req, res, email, callbackCode, name

      if name == 'script_in_script' or name == 'js'
        res.set 'Content-Type', 'text/plain'
        res.end "alert('I\\'ve managed to execute javascript in your browser. That is probably a very bad security hole. Please contact me using the contact link on emailprivacytester.com so I can help sort it out.')"
      else if name == 'meta_refresh'
        sendHTML res, 'callback_meta_refresh'
      else
        res.set 'Content-Type', 'text/plain'
        res.end ''

    onFail = () ->
      return if countDown == -1
      countDown = -1
      res.end ''

    getResults 'callback_code', callbackCode, ( err, e ) ->
      return onFail() if err? or not e?
      email = e
      onSuccess() if --countDown == 0

    tests.get name, ( t ) ->
      return onFail() unless t?
      type = t.type
      onSuccess() if --countDown == 0

  testCallbackHTTP = ( req, res, email, callbackCode, name, clientIP ) ->

    ## Calculate additional callback info
    httpXForwardedFor = (req.get('x-forwarded-for')||'').split /\s*,\s*/

    ## Get the client IP. Use the X-Forwarded-For header if necessary
    ignoreIPrx = /^(127|192\.168|10|172\.(1[6-9]|2\d|3[01]))\./
    while httpXForwardedFor.length and clientIP.match ignoreIPrx
      clientIP = httpXForwardedFor.pop()

    ## Remove RFC 3330/1918 addresses and the client IP from X-Forwarded-For
    httpXForwardedFor = ( ip for ip in httpXForwardedFor when ip is not clientIP and not ip.match ignoreIPrx )
    httpXForwardedFor = if httpXForwardedFor.length == 0 then null else httpXForwardedFor.join ','

    sql = 'INSERT INTO callback SET email_id=?, ctime=?, name=?, client_ip=?, http_user_agent=?, http_x_forwarded_for=?'
    dbh.query sql, [ email.email_id, Date.now(), name, clientIP, req.get('user-agent'), httpXForwardedFor ], ( err, info ) ->
      ## Let long-poll clients know about the update
      emitter.emit "newCallback#{email.lookupCode}" unless err?

  testCallbackEmail = ( req, res, email, callbackCode, name ) ->

    ctime     = req.body?.ctime
    emailData = req.body?.emailData
    subject   = emailData.subject

    sql = 'INSERT INTO callback SET email_id=?, ctime=?, name=?, email_subject=?'
    dbh.query sql, [ email.email_id, ctime, name, subject ], ( err, info ) ->
      ## Let long-poll clients know about the update
      emitter.emit "newCallback#{email.lookupCode}" unless err?
   
  testCallbackDNS = ( req, res, email, callbackCode, name ) ->
     
    ctime    = req.body?.ctime
    clientIP = req.body?.clientIP

    sql = 'INSERT INTO callback SET email_id=?, ctime=?, name=?, client_ip=?'
    dbh.query sql, [ email.email_id, ctime, name, clientIP ], ( err, info ) ->
      ## let long-poll clients know about the update
      emitter.emit "newCallback#{email.lookupCode}" unless err?

## Status callbacks

  exports.emailStatusCallback = ( req, res ) ->

    ## Get rid of the client ASAP
    sendJSON res, 'OK'

    ## Parse args
    callbackCode = req.params.callbackCode
    status       = req.body.status
    message      = req.body.message
    mtime        = req.body.mtime

    getResults 'callback_code', callbackCode, ( err, email ) ->
      return if err? or not email?

      sql = 'INSERT INTO email_log SET email_log_type_id=(SELECT email_log_type_id FROM email_log_type WHERE name=?), email_id=?, ctime=?, message=?'
      dbh.query sql, [ status, email.email_id, mtime, message ], ( err, info ) ->
        ## Let long-poll clients now about the update
        emitter.emit "newEmailLog#{email.lookupCode}" unless err?

## Long-poll meta refresh for new results 

  exports.metaRefresh = ( req, res ) ->
    lookupCode = req.params.lookupCode
    emailLogId = req.params.emailLogId

    ## Detect when a new entry is added to email_log with a higher email_log_id and force an instant refresh
    ## Time out after 25 seconds and do a refresh even if there has been no new log entry

    pid = null
    listener = () ->
      return unless pid?
      clearTimeout pid
      pid = null
      emitter.removeListener "newEmailLog#{lookupCode}", listener
      emitter.removeListener "newCallback#{lookupCode}", listener

      ## Delay the redirect as a buffer for when multiple events happen close together
      setTimeout () =>
        res.redirect 302, "#{conf.site.path}#{lookupCode}#testHits"
      , 250

    ## If the status has already updated since last we checked then refresh immediately, otherwise wait:

    pid = setTimeout listener, 25000
    emitter.on "newEmailLog#{lookupCode}", listener
    emitter.on "newCallback#{lookupCode}", listener
    getNewEmailStatus lookupCode, emailLogId, ( err, status, emailLogId ) -> if status? then listener() 

## Send the results in JSON form via XHR

  exports.getResultsAJAX = ( req, res ) ->
    lookupCode = req.params.lookupCode
    emailLogId = req.params.emailLogId
    callbackId = req.params.callbackId

    pid = null
    listener = ( data ) ->
      return unless pid?
      clearTimeout pid
      pid = null
      emitter.removeListener "newEmailLog#{lookupCode}", listener
      emitter.removeListener "newCallback#{lookupCode}", listener

      if data?
        sendJSON res, data
      else
        ## Delay sending data as a buffer for when multiple events happen close together
        #setTimeout () =>
          getNewData lookupCode, emailLogId, callbackId, ( data, err ) -> sendJSON res, data
        #, 250 

    pid = setTimeout () =>
      listener {}
    , 25000
    emitter.on "newEmailLog#{lookupCode}", listener
    emitter.on "newCallback#{lookupCode}", listener

    getNewData lookupCode, emailLogId, callbackId, ( data, err ) -> listener data if data.status or data.hits

## Send the results in HTML form

  exports.getResultsHTML = ( req, res ) ->
    lookupCode = req.params.lookupCode

    getResults 'lookup_code', lookupCode, ( err, email ) ->
      if err?       then return sendHTML res, '500', status: 500
      if not email? then return sendHTML res, 'results_404', status: 404

      opt = email: email, systemTime: Date.now(), emailLogId: 0, callbackId: 0
      opt.js = true if req.method == 'POST'

      countDown = 2
      tests.get (data) ->
        opt.tests = data
        if --countDown == 0 then sendHTML res, 'results', opt

      getNewData lookupCode, 0, 0, ( data, err ) ->
        if err? then return sendHTML res, '500', status: 500
        opt[k]=v for k, v of data
        if --countDown == 0 then sendHTML res, 'results', opt

## Look up results

  getResults = ( lookupType, code, callback ) ->
    dbh.query "SELECT email_id, lookup_code AS lookupCode, ctime FROM email WHERE #{lookupType}=?", [code], ( err, info ) ->
      callback err if err?
      if info.length
        info[0].ctimeAge = humanAge info[0].ctime
        callback err, info[0]
      else
        callback err

## Look for updates to the email log table since your last check

  getNewEmailStatus = ( lookupCode, emailLogId, callback ) ->
    dbh.query 'SELECT email_log.email_log_id AS emailLogId, email_log_type.name AS status, email_log.ctime AS mtime, email_log.message FROM email LEFT JOIN email_log ON email.email_id=email_log.email_id LEFT JOIN email_log_type ON email_log.email_log_type_id=email_log_type.email_log_type_id WHERE email.lookup_code=? AND email_log.email_log_id > ? ORDER BY email_log.email_log_id', [ lookupCode, emailLogId ], ( err, rows ) ->
      callback err if err?
    
      mostRecentLog = null
      if rows.length
        for log in rows
          emailLogId = log.emailLogId
          if not mostRecentLog?
            mostRecentLog = log
          else if mostRecentLog.status == 'queued'
            mostRecentLog = log if log.mtime >= mostRecentLog.mtime
        mostRecentLog.mtimeAge = humanAge(mostRecentLog.mtime) if mostRecentLog?

      callback err, mostRecentLog, emailLogId

## Look for new test hits since your last check

  getNewTestHits = ( lookupCode, callbackId, callback ) ->
    sql = 'SELECT callback.callback_id AS callbackId, callback.ctime, callback.name, callback.client_ip AS clientIP, callback.http_user_agent AS httpUserAgent, callback.http_x_forwarded_for as httpXForwardedFor FROM email LEFT JOIN callback ON email.email_id=callback.email_id WHERE email.lookup_code=? AND callback.callback_id > ? ORDER BY callback.callback_id DESC'

    dbh.query sql, [ lookupCode, callbackId ], ( err, rows ) ->
      if err? or rows.length == 0 then return callback err, null, callbackId
      results = {}
      for hit in rows
        name = hit.name
        delete hit.name
        hit.ctimeAge = minHumanAge hit.ctime
        results[name] = [] unless results[name]?
        results[name].push hit
      callbackId = rows[0].callbackId
      callback err, results, callbackId

## Look for new data that needs to be sent to the client

  getNewData = ( lookupCode, emailLogId, callbackId, callback ) ->
    [ countDown, opt, anyErr ] = [ 2, {}, null ]

    getNewEmailStatus lookupCode, emailLogId, ( err, status, emailLogId ) ->
      anyErr          = err if err?
      opt.emailStatus = status if status?
      opt.emailLogId  = emailLogId if emailLogId?
      if --countDown  == 0 then callback opt, anyErr

    getNewTestHits lookupCode, callbackId, ( err, hits, callbackId ) ->
      anyErr         = err if err?
      opt.hits       = hits if hits?
      opt.callbackId = callbackId if callbackId?
      if --countDown == 0 then callback opt, anyErr

## Take a time and return how long ago it was in human readable format

  humanAge = ( t ) ->
    sec  = parseInt((Date.now()-t)/1000)
    hour = parseInt(sec/3600)
    sec -= hour*3600
    min  = parseInt(sec/60)
    sec -= min*60
                
    parts = []
    if hour        then parts.push "#{hour} hour#{if hour == 1 then '' else 's'}"
    if hour or min then parts.push "#{min} minute#{if min == 1 then '' else 's'}"
    parts.push "#{sec} second#{if sec==1 then '' else 's'}"
                
    return parts.join(', ')+' ago'

  minHumanAge = ( t ) ->
    sec = parseInt((Date.now()-t)/1000)
    hour = parseInt(sec/3600)
    sec -= hour*3600
    min  = parseInt(sec/60)
    sec -= min*60

    return if hour then "#{hour}h:#{min}m:#{sec}s" else if min then "#{min}m:#{sec}s" else "#{sec}s"

## Send HTML/JSON

  sendHTML = ( res, name, obj ) ->                        
    obj?.conf = conf unless obj?.conf?
    res.charset = 'UTF-8'
    res.set 'Content-Type', 'text/html'
    res.render name, obj

  sendJSON = ( res, obj ) ->
    res.charset = 'UTF-8'
    res.set 'Content-Type', 'application/json'
    res.end JSON.stringify obj
