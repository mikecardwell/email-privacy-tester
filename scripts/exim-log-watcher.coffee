#!/usr/bin/env coffee

## Dependencies

  conf     = require "#{__dirname}/../conf/main.conf"
  tailer   = require 'tailfd'
  punycode = require 'punycode'

  util = require 'util'

  domain_rx = punycode.toASCII(conf.site.domain).replace /\./g, '\\.'
  in_rx     = new RegExp "^\\S+ \\S+ (\\S+) <= env\\.([a-f0-9]{16})\\.cb@#{domain_rx} "
  out_rx    = new RegExp "^(\\S+ \\S+) (\\S+) => \\S+ .+? H=(\\S+) \\[(\\S+)\\]:25(?: .+)*? C=\"(.+?)\""
  defer_rx  = new RegExp "^(\\S+ \\S+) (\\S+) == \\S+ .+? T=\\S+ defer \\(\\S+\\): (.+)"
  reject_rx = new RegExp "^(\\S+ \\S+) (\\S+) \\*\\* \\S+ .+? T=\\S+: (.+)"
  other_rx  = new RegExp "^(\\S+ \\S+) (\\S+) ([^-=<].+)"

## Watch and parse the logs

  watch = () ->
    codes = {}

    tailer.tail '/var/log/exim4/mainlog', start: 0, timeout: 60000, timeoutInterval: 10000, ( line ) ->
      match = in_rx.exec line
      if match?
        messageId    = match[1]
        callbackCode = match[2]
        return codes[messageId]=callbackCode

      match = out_rx.exec line
      if match?
        mtime        = new Date(match[1]).getTime()
        messageId    = match[2]
        hostName     = match[3]
        hostIp       = match[4]
        message      = match[5]
        callbackCode = codes[messageId]
        return unless callbackCode?
        delete codes[messageId]
        return markEmailSent callbackCode, mtime, "Message accepted by #{hostName} (#{hostIp}) - #{message}"

      match = defer_rx.exec line
      if match?
        mtime        = new Date(match[1]).getTime()
        messageId    = match[2]
        message      = match[3]
        callbackCode = codes[messageId]
        return unless callbackCode?
        return markEmailQueued callbackCode, mtime, message

      match = reject_rx.exec line
      if match?
        mtime        = new Date(match[1]).getTime()
        messageId    = match[2]
        message      = match[3]
        callbackCode = codes[messageId]
        return unless callbackCode?
        delete codes[messageId]
        return markEmailRejected callbackCode, mtime, message

      match = other_rx.exec line
      if match?
        mtime        = new Date(match[1]).getTime()
        messageId    = match[2]
        message      = match[3]
        callbackCode = codes[messageId]
        return unless callbackCode?
        return markEmailQueued callbackCode, mtime, message

## Mark an email as "sent"

  markEmailSent = ( callbackCode, mtime, message ) ->
    web_callback callbackCode, { status: 'sent', mtime: mtime, message: message }, (success) ->
      if success then  console.log "#{new Date mtime} Sent #{callbackCode} - #{message}"

## Mark an email as "rejected"

  markEmailRejected = ( callbackCode, mtime, message ) ->
    web_callback callbackCode, { status: 'rejected', mtime: mtime, message: message }, (success) ->
      if success then console.log "#{new Date mtime} Rejected #{callbackCode} - #{message}"

## Log information about an email. Usually deferred information

  markEmailQueued = ( callbackCode, mtime, message ) ->
    return if message == 'Completed'
    return if message == 'Connection refused'
    return if message.indexOf('Spool file is locked ') == 0
    web_callback callbackCode, { status: 'queued', mtime: mtime, message: message }, (success) ->
      if success then console.log "#{new Date mtime} Queued #{callbackCode} - #{message}"

## Initiate a web callback. TODO: If there is an error, queue the callback and try it again later

  web_callback = ( callbackCode, data, cb ) ->
    data = JSON.stringify data

    opt =
      host:  conf.site.domain
      path:  "#{conf.site.path}emailStatusCB/#{callbackCode}"
      method:  'POST'
      headers: 'Content-Type': 'application/json', 'Content-Length': data.length

    http = require conf.site.proto
    req  = http.request opt, ( res ) ->
      if res.statusCode == 200
        cb true
      else
        cb false

    req.on 'error', (e) ->
      cb false

    req.write data
    req.end()

## Begin watching

  watch()
