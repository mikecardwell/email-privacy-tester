#!/usr/bin/env coffee

## Dependencies

  conf       = require "#{__dirname}/../conf/main.conf"
  MailParser = require('mailparser').MailParser

## Parse arguments

  [ email_type, callback_code ] = []
  do () ->
    rx = new RegExp "^(?:(env|from|rt|rr|dn)\.)([a-f0-9]{16})$"
    match = rx.exec process.argv[2]
    if match
      email_type    = {
        env:  'sender'
        from:  'from'
        rt:  'reply_to'
        rr:  'return_receipt'
        dn:  'disposition_notification'
      }[match[1]||'']
      callback_code = match[2]
    else
      console.error "Unable to determine which email this is in reply to"
      process.exit 1

## Read from STDIN, a maximum of 1MB of data

  do () ->
    truncateAt = 102400
    plain = ''
    process.stdin.resume()
    process.stdin.on 'data', (chunk) ->
      return if plain.length == truncateAt
      plain += chunk
      if plain.length > truncateAt then plain = plain.substr 0, truncateAt
    process.stdin.on 'end', () ->
      mail_parse plain, ( emailData ) ->
        web_callback callback_code, email_type, { ctime: Date.now(), emailData: emailData }, (success) ->
          process.exit 0

## Initiate a web callback

  web_callback = ( callback_code, test_name, data, cb ) ->
    data = JSON.stringify data

    opt =
      host:   conf.site.domain
      path:   "#{conf.site.path}cb/#{callback_code}/#{test_name}"
      method: 'POST'
      headers: 'Content-Type': 'application/json', 'Content-Length': data.length

    http = require conf.site.proto
    req  = http.request opt, ( res ) -> if res.statusCode == 200 then cb true else cb false

    req.on 'error', (e) -> cb false

    req.write data
    req.end()

## Parse an email for interesting data

  mail_parse = ( email, callback ) ->
    email = email.replace /^From [^\n]+\n/,''

    mailParser = new MailParser()
    mailParser.write email
    mailParser.end()

    mailParser.on 'end', ( mail ) ->
      return unless mail?.subject?

      collect = subject: mail.subject

      if mail.headers.from?      then collect.from = mail.headers.from
      if mail.text?       then collect.body = mail.text.substr( 0, 255 ).replace /[\r\n]+$/, ''
      if Date.parse mail.headers.date then collect.date = Date.parse mail.headers.date

      callback collect
