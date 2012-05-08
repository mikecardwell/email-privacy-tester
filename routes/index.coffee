## Required modules

  util      = require 'util'
  mysql     = require 'mysql'
  ept_email = require 'ept/email'
  tests     = require 'ept/tests'
  conf      = require "#{__dirname}/../conf/main.conf"

## Connect to MySQL

  dbh = mysql.createClient conf.db

## Set up an hourly job to delete old results

  setInterval () ->
    dbh.query 'DELETE FROM email WHERE ctime < UNIX_TIMESTAMP(NOW())*1000 - ?', [ conf.expireDataAfter * 1000 ], ( err, info ) ->
      if err? then console.log err
  , 3600 * 1000

## Home page

  exports.index   = ( req, res ) -> sendHTML res, 'index'
  exports.about   = ( req, res ) -> sendHTML res, 'about'
  exports.privacy = ( req, res ) -> sendHTML res, 'privacy'

## Display information about a particular test

  exports.test = ( req, res ) ->
    tests.get req.params.name, (test) ->
      if test?
        sendHTML res, 'test', test: test
      else
        sendHTML res, 'test', status: 404

## When the user submits an email

  exports.submit = ( req, res ) ->
    email = ept_email.emailToUnicode req.body?.email || ''
    email = email.replace /[\r\n]+/g, ''
    email = email.replace /^\s*(.*?)\s*$/, '$1'

    client_ip = clientIP req
    submit email, client_ip, ( info ) ->
      if info.error?
        sendHTML res, 'index', email: email, error: info.error
      else
        console.log "Email sent to #{email}, lookup code: #{info.lookup_code}"
        res.redirect "#{conf.site.path}#{info.lookup_code}", 302

## Handle opt outs

  exports.optout  = ( req, res ) ->
    data = {}
    if req.body?.email
      email = ept_email.emailToUnicode req.body.email
      email = email.replace " ", "+"
      optedOut email, ( status ) ->
        if status then return sendHTML res, 'optout', email: email, success: true
        if ept_email.validateFormat email
          salt = getSalt()
          sql = 'INSERT INTO optout SET ctime=?, client_ip=?, salt=?, salted_email_hash=MD5(CONCAT(?,LOWER(?)))'
          dbh.query sql, [ Date.now(), clientIP(req), salt, salt, removePlusAddressing email ], ( err, info ) ->
            if err?
              sendHTML res, 'optout', email: email, error: "System error: Problem inserting into database"
            else
              sendHTML res, 'optout', email: email, success: true
        else
          sendHTML res, 'optout', email: email, error: "Invalid email address"
    else if req.query?.email
      sendHTML res, 'optout', email: ept_email.emailToUnicode(req.query.email).replace " ", "+"
    else
      sendHTML res, 'optout'

## Email submission

  submit = ( email, client_ip, cb ) ->
    authoriseSending email, client_ip, ( err ) ->
      if err? then return cb error: err

      local_part = email.replace /^(.+)@.+/, '$1'
      domain     = email.replace /.+@/, ''

      salt = getSalt()
      sql = 'INSERT INTO email SET salt=?, salted_email_hash=MD5(CONCAT(?,LOWER(?))), client_ip=?, callback_code=SUBSTRING(MD5(RAND()),3,16), lookup_code=SUBSTRING(MD5(RAND()),3,16), ctime=?'
      dbh.query sql, [ salt, salt, removePlusAddressing("#{local_part}@#{domain}"), client_ip, Date.now() ], (err, info) ->
        if err?
          cb error: "System error. Please try again"
        else
          dbh.query 'SELECT lookup_code, callback_code FROM email WHERE email_id=?', [ info.insertId ], (err, info) ->
            if err?
              cb error: "System error. Please try again"
            else
              info = info[0]
              ept_email.sendEmail {
                base_domain:  conf.site.domain
                base_url:  "#{conf.site.proto}://#{conf.site.domain}#{conf.site.path}"
                ip:    client_ip
                callback_code:  info.callback_code
                lookup_code:  info.lookup_code
                to:    email
              },
              ( err, status ) ->
                if err?
                  cb error: err
                else
                  cb lookup_code: info.lookup_code

  clientIP = ( req ) ->
    client_ip   = req.socket.remoteAddress
    if client_ip is '127.0.0.1' then client_ip = req.header('x-forwarded-for').replace /.*,\s*/, ''
    return client_ip

  sendHTML = ( res, name, obj ) ->
    #sendCacheHeaders res, 1800 unless obj?
    obj?.conf = conf unless obj?.conf?
    res.charset = 'UTF-8'
    res.header 'Content-Type', 'text/html'
    res.render name, obj

  sendJSON = ( res, obj ) ->
    res.charset = 'UTF-8'
    res.header 'Content-Type', 'application/json'
    res.end JSON.stringify obj

  sendCacheHeaders = ( res, seconds ) ->
    res.header 'Cache-Control', "max-age=#{seconds}, public"
    res.header 'Expires', new Date( Date.now() + seconds * 1000 ).toUTCString()

  getSalt = () ->
    salt = ''
    saltChars = 'abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYS1234567890'.split ''
    for x in [1..40]
      salt += saltChars[parseInt(Math.random()*saltChars.length)]
    return salt

  authoriseSending = ( email, client_ip, cb ) ->
    [ done, countdown ] = [ false, 4 ]

    ept_email.validate email, ( err ) ->
      return if done
      if err?
        cb err
        done = true
      else if --countdown == 0 then cb()
    optedOut email, ( status ) ->
      return if done
      if status
        cb 'That address has opted out of receiving emails from this system'
        done = true
      else if --countdown == 0 then cb()
    emailRate email, ( counter ) ->
      return if done
      if counter >= conf.ratelimit.email
        cb 'You have reached the maximum number of emails to that address for this period'
        done = true
      else if --countdown == 0 then cb()
    ipRate client_ip, ( counter ) ->
      return if done
      if counter >= conf.ratelimit.ip
        cb 'You have hit the maximum number of emails for your IP address for this period'
        done = true
      else if --countdown == 0 then cb()

  optedOut = ( email, cb ) ->
    sql = 'SELECT ctime FROM optout WHERE salted_email_hash=MD5(CONCAT(salt,LOWER(?))) LIMIT 1'
    dbh.query sql, [ ept_email.emailToUnicode removePlusAddressing email ], ( err, info ) ->
      if info? and info.length == 1 then return cb true
      cb false

  emailRate = ( email, cb ) ->
    unless email.match /.@./ then return cb 0
    local_part = email.replace /(.+)@.+/, '$1'
    domain     = email.replace /.+@/, ''
    sql = 'SELECT COUNT(*) AS counter FROM email WHERE salted_email_hash=MD5(CONCAT(salt,LOWER(?))) AND ctime > ?'
    dbh.query sql, [ removePlusAddressing("#{local_part}@#{domain}"), Date.now()-86400000 ], ( err, info ) ->
      cb if err? then 0 else info[0].counter

  ipRate = ( ip, cb ) ->
    sql = 'SELECT COUNT(*) AS counter FROM email WHERE client_ip=? AND ctime > ?'
    dbh.query sql, [ ip, Date.now()-86400000 ], ( err, info ) ->
      cb if err? then 0 else info[0].counter

  removePlusAddressing = ( email ) ->
    capture = email.match /^(.+)(?:\+.*)@((?:gmail|googlemail)\.com)$/i
    return if capture? then "#{capture[1]}@#{capture[2]}" else email
