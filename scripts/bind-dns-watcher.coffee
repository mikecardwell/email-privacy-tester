#!/usr/bin/env coffee

## Dependencies

  conf     = require "#{__dirname}/../conf/main.conf"
  tailer   = require 'tailfd'
  punycode = require 'punycode'

  util = require 'util'

  domain_rx = punycode.toASCII(conf.site.domain).replace /\./g, '\\.'

  in_rx = new RegExp "^(\\S+ \\S+) .*: client (\\S+?)#\\d+: query: ([a-zA-Z0-9]+)\\.(anchor|link)-test\\.ept\\.#{domain_rx} IN A(?:AAA)? "

  cache         = {}
  cache_timeout = 3600000

## Watch and parse the logs

  watch = () ->

    tailer.tail conf.dns.bind, start: 0, timeout: 60000, timeoutInterval: 10000, ( line ) ->
      capture = in_rx.exec line
      return unless capture?

      mtime        = new Date(capture[1]).getTime()
      clientIP     = capture[2]
      callbackCode = capture[3]
      testName     = "dns_#{capture[4]}"

      return if clientIP in conf.dns.ignore

      ## Expire old cache entries
      for k, v of cache
        delete cache[k] if v < Date.now() - cache_timeout

      cacheKey = "#{clientIP} #{callbackCode} #{testName} #{parseInt mtime/1000}"
      return if cache[cacheKey]?
      cache[cacheKey]=Date.now()

      web_callback callbackCode, testName, { ctime: mtime, clientIP: clientIP }, (success) ->
        if success
          console.log "#{new Date mtime} #{testName} - #{clientIP}"
        else
          delete cache[cacheKey]

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


## Begin watching

  watch()
