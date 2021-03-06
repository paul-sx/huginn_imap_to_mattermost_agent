require 'base64'
require 'delegate'
require 'net/imap'
require 'mail'

module Agents
  class ImapToMattermostAgent < Agent
    cannot_receive_events!
    cannot_create_events!
    can_dry_run!
    default_schedule 'every_30m'

    description <<-MD
    The Imap Folder Agent checks an IMAP server in specified folders and creates Events based on new mails found since the last run. In the first visit to a folder, this agent only checks for the initial status and does not create events.

    Specify an IMAP server to connect with `host`, and set `ssl` to true if the server supports IMAP over SSL.  Specify `port` if you need to connect to a port other than standard (143 or 993 depending on the `ssl` value).

    Specify login credentials in `username` and `password`.

    List the names of folders to check in `folders`.

    To narrow mails by conditions, build a `conditions` hash with the following keys:

    - `subject`
    - `body`
        Specify a regular expression to match against the decoded subject/body of each mail.

        Use the `(?i)` directive for case-insensitive search.  For example, a pattern `(?i)alert` will match "alert", "Alert"or "ALERT".  You can also make only a part of a pattern to work case-insensitively: `Re: (?i:alert)` will match either "Re: Alert" or "Re: alert", but not "RE: alert".

        When a mail has multiple non-attachment text parts, they are prioritized according to the `mime_types` option (which see below) and the first part that matches a "body" pattern, if specified, will be chosen as the "body" value in a created event.

        Named captures will appear in the "matches" hash in a created event.

    - `from`, `to`, `cc`
        Specify a shell glob pattern string that is matched against mail addresses extracted from the corresponding header values of each mail.

        Patterns match addresses in case insensitive manner.

        Multiple pattern strings can be specified in an array, in which case a mail is selected if any of the patterns matches. (i.e. patterns are OR'd)

    - `mime_types`
        Specify an array of MIME types to tell which non-attachment part of a mail among its text/* parts should be used as mail body.  The default value is `['text/plain', 'text/enriched', 'text/html']`.

    - `is_unread`
        Setting this to true or false means only mails that is marked as unread or read respectively, are selected.

        If this key is unspecified or set to null, it is ignored.

    - `has_attachment`
    
        Setting this to true or false means only mails that does or does not have an attachment are selected.

        If this key is unspecified or set to null, it is ignored.

    Set `mark_as_read` to true to mark found mails as read.
    Set `delete` to true to delete found mails.

    Set `event_headers` to a list of header names you want to include in a `headers` hash in each created event, either in an array of string or in a comma-separated string.

    Set `event_headers_style` to one of the following values to normalize the keys of "headers" for downstream agents' convenience:

      * `capitalized` (default) - Header names are capitalized; e.g. "Content-Type"
      * `downcased` - Header names are downcased; e.g. "content-type"
      * `snakecased` - Header names are snakecased; e.g. "content_type"

    Set `include_raw_mail` to true to add a `raw_mail` value to each created event, which contains a *Base64-encoded* blob in the "RFC822" format defined in [the IMAP4 standard](https://tools.ietf.org/html/rfc3501).  Note that while the result of Base64 encoding will be LF-terminated, its raw content will often be CRLF-terminated because of the nature of the e-mail protocols and formats.  The primary use case for a raw mail blob is to pass to a Shell Command Agent with a command like `openssl enc -d -base64 | tr -d '\r' | procmail -Yf-`.

    Each agent instance memorizes the highest UID of mails that are found in the last run for each watched folder, so even if you change a set of conditions so that it matches mails that are missed previously, or if you alter the flag status of already found mails, they will not show up as new events.

    Also, in order to avoid duplicated notification it keeps a list of Message-Id's of 100 most recent mails, so if multiple mails of the same Message-Id are found, you will only see one event out of them.
    MD

    IDCACHE_SIZE = 100

    FNM_FLAGS = [:FNM_CASEFOLD, :FNM_EXTGLOB].inject(0) { |flags, sym|
      if File.const_defined?(sym)
        flags | File.const_get(sym)
      else
        flags
      end
    }

    def default_options
      {
        'expected_update_period_in_days' => "1",
        'host' => 'imap.gmail.com',
        'ssl' => true,
        'username' => 'your.account',
        'password' => 'your.password',
        'folders' => %w[INBOX],
        'conditions' => {},
        'mattermost_server_url' => 'https://mattermost.com',
        'mattermost_team' => 'team_name',
        'mattermost_channel' => 'channel_name', 
        'mattermost_token' => '{% credential mattermost_token %}',
        'message' => '{{message}}'
      }
    end

    def validate_options

      errors.add(:base, 'mattermost_server_url missing') unless options['mattermost_server_url'].present?
      errors.add(:base, 'mattermost_team missing') unless options['mattermost_team'].present?
      errors.add(:base, 'mattermost_channel missing') unless options['mattermost_channel'].present?
      errors.add(:base, 'mattermost_token missing') unless options['mattermost_token'].present?

      %w[host username password].each { |key|
        String === options[key] or
          errors.add(:base, '%s is required and must be a string' % key)
      }

      if options['port'].present?
        errors.add(:base, "port must be a positive integer") unless is_positive_integer?(options['port'])
      end

      %w[ssl mark_as_read delete include_raw_mail].each { |key|
        if options[key].present?
          if boolify(options[key]).nil?
            errors.add(:base, '%s must be a boolean value' % key)
          end
        end
      }

      case mime_types = options['mime_types']
      when nil
      when Array
        mime_types.all? { |mime_type|
          String === mime_type && mime_type.start_with?('text/')
        } or errors.add(:base, 'mime_types may only contain strings that match "text/*".')
        if mime_types.empty?
          errors.add(:base, 'mime_types should not be empty')
        end
      else
        errors.add(:base, 'mime_types must be an array')
      end

      case folders = options['folders']
      when nil
      when Array
        folders.all? { |folder|
          String === folder
        } or errors.add(:base, 'folders may only contain strings')
        if folders.empty?
          errors.add(:base, 'folders should not be empty')
        end
      else
        errors.add(:base, 'folders must be an array')
      end

      case conditions = options['conditions']
      when Hash
        conditions.each { |key, value|
          value.present? or next
          case key
          when 'subject', 'body'
            case value
            when String
              begin
                Regexp.new(value)
              rescue
                errors.add(:base, 'conditions.%s contains an invalid regexp' % key)
              end
            else
              errors.add(:base, 'conditions.%s contains a non-string object' % key)
            end
          when 'from', 'to', 'cc'
            Array(value).each { |pattern|
              case pattern
              when String
                begin
                  glob_match?(pattern, '')
                rescue
                  errors.add(:base, 'conditions.%s contains an invalid glob pattern' % key)
                end
              else
                errors.add(:base, 'conditions.%s contains a non-string object' % key)
              end
            }
          when 'is_unread', 'has_attachment'
            case boolify(value)
            when true, false
            else
              errors.add(:base, 'conditions.%s must be a boolean value or null' % key)
            end
          end
        }
      else
        errors.add(:base, 'conditions must be a hash')
      end

      if options['expected_update_period_in_days'].present?
        errors.add(:base, "Invalid expected_update_period_in_days format") unless is_positive_integer?(options['expected_update_period_in_days'])
      end
    end

    def working?
      !recent_error_logs?
      # Implement me! Maybe one of these next two lines would be a good fit?
      # checked_without_error?
      # received_event_without_error?
    end

    def check
      each_unread_mail { |mail, notified|
        message_id = mail.message_id
        body_parts = mail.body_parts(mime_types)
        attachment_parts = mail.body_attachments
        matched_part = nil
        matches = {}

        interpolated['conditions'].all? { |key, value|
          case key
          when 'subject'
            value.present? or next true
            re = Regexp.new(value)
            if m = re.match(mail.scrubbed(:subject))
              m.names.each { |name|
                matches[name] = m[name]
              }
              true
            else
              false
            end
          when 'body'
            value.present? or next true
            re = Regexp.new(value)
            matched_part = body_parts.find { |part|
               if m = re.match(part.scrubbed(:decoded))
                 m.names.each { |name|
                   matches[name] = m[name]
                 }
                 true
               else
                 false
               end
            }
          when 'from', 'to', 'cc'
            value.present? or next true
            begin
              # Mail::Field really needs to define respond_to_missing?
              # so we could use try(:addresses) here.
              addresses = mail.header[key].addresses
            rescue NoMethodError
              next false
            end
            addresses.any? { |address|
              Array(value).any? { |pattern|
                glob_match?(pattern, address)
              }
            }
          when 'has_attachment'
            boolify(value) == mail.has_attachment?
          when 'is_unread'
            true  # already filtered out by each_unread_mail
          else
            log 'Unknown condition key ignored: %s' % key
            true
          end
        } or next

        if notified.include?(mail.message_id)
          log 'Ignoring mail: %s (already notified)' % message_id
        else
          matched_part ||= body_parts.first

          if matched_part
            mime_type = matched_part.mime_type
            body = matched_part.scrubbed(:decoded)
          else
            mime_type = 'text/plain'
            body = ''
          end

          log 'Emitting an event for mail: %s' % message_id

          payload = {
            'message_id' => message_id,
            'folder' => mail.folder,
            'subject' => mail.scrubbed(:subject),
            'from' => mail.from_addrs.first,
            'to' => mail.to_addrs,
            'cc' => mail.cc_addrs,
            'date' => (mail.date.iso8601 rescue nil),
            'mime_type' => mime_type,
            'body' => body,
            'matches' => matches,
            'has_attachment' => mail.has_attachment?,
          }

          if boolify(interpolated['include_raw_mail'])
            payload['raw_mail'] = Base64.encode64(mail.raw_mail)
          end

          if interpolated['event_headers'].present?
            headers = mail.header.each_with_object({}) { |field, hash|
              name = field.name
              hash[name] = (v = hash[name]) ? "#{v}\n#{field.value.to_s}" : field.value.to_s
            }
            payload.update(event_headers_payload(headers))
          end

          file_ids = attachment_parts.each_with_object([]) do |attachment, li|
            li << upload_file_to_mattermost(attachment)
          end

          send_message(payload, file_ids.flatten)


          #create_event payload: payload

          notified << mail.message_id if mail.message_id
        end

        if boolify(interpolated['mark_as_read'])
          log 'Marking as read'
          mail.mark_as_read unless dry_run?
        end

        if boolify(interpolated['delete'])
          log 'Deleting'
          mail.delete unless dry_run?
        end
      }
    end

    def send_message(message_context, file_ids)

      interpolate_with(message_context) do
        payload = {
          channel_id: channel_id,
          message: interpolated['message'],
          file_ids: file_ids
        }
        log "Posting to mattermost: #{payload.to_json}"
        mattermost_client.post("/api/v4/posts", payload.to_json)
      end

    end

    def upload_file_to_mattermost(mail_part)
      log "Uploading file #{mail_part.filename}"
      mail_mime = mail_part.content_type
      mail_filename = mail_part.filename

      mail_streamio = StringIO::new(mail_part.body.decoded)

      payload = {channel_id: channel_id()}
      payload[:files] = Faraday::UploadIO.new(mail_streamio, mail_mime, mail_filename)

      response = mattermost_client.post("/api/v4/files", payload)
      mm_file = JSON.parse(response.body)

      mm_file['file_infos'].each_with_object([]) do |fi, li|
        li <<= fi['id']
      end
    end

    def mattermost_client
      @mattermost_client ||= Faraday.new(url: interpolated['mattermost_server_url']) do |builder|
        builder.request :retry
        builder.request :multipart
        builder.authorization :Bearer, interpolated['mattermost_token']
        builder.adapter :net_http
      end
    end
    
    def channel_id
      team_name = interpolated['mattermost_team']
      channel_name = interpolated['mattermost_channel']

      memory['channel_lookup'] ||= {}
      memory['channel_lookup'][team_name] ||= begin
        team_info = {}
        resp = mattermost_client.get("/api/v4/teams/name/#{team_name}")
        if resp.status != 200
          #Add error
        end
        body = JSON.parse(resp.body)
        team_info['_id'] = body['id']
        team_info
      end
      memory['channel_lookup'][team_name][channel_name] ||= begin
        team_id = memory['channel_lookup'][team_name]['_id']
        resp = mattermost_client.get("/api/v4/teams/#{team_id}/channels/name/#{channel_name}")
        unless resp.status == 200

        end
        body = JSON.parse(resp.body)
        body['id']
      end
      memory['channel_lookup'][team_name][channel_name]
    end
    
    def each_unread_mail
      host, port, ssl, username = interpolated.values_at(:host, :port, :ssl, :username)
      ssl = boolify(ssl)
      port = (Integer(port) if port.present?)

      log "Connecting to #{host}#{':%d' % port if port}#{' via SSL' if ssl}"
      Client.open(host, port: port, ssl: ssl) { |imap|
        log "Logging in as #{username}"
        imap.login(username, interpolated[:password])

        # 'lastseen' keeps a hash of { uidvalidity => lastseenuid, ... }
        lastseen, seen = self.lastseen, self.make_seen

        # 'notified' keeps an array of message-ids of {IDCACHE_SIZE}
        # most recent notified mails.
        notified = self.notified

        interpolated['folders'].each { |folder|
          log "Selecting the folder: %s" % folder

          imap.select(Net::IMAP.encode_utf7(folder))
          uidvalidity = imap.uidvalidity

          lastseenuid = lastseen[uidvalidity]

          if lastseenuid.nil?
            maxseq = imap.responses['EXISTS'].last

            log "Recording the initial status: %s" % pluralize(maxseq, 'existing mail')

            if maxseq > 0
              seen[uidvalidity] = imap.fetch(maxseq, 'UID').last.attr['UID']
            end

            next
          end

          seen[uidvalidity] = lastseenuid
          is_unread = boolify(interpolated['conditions']['is_unread'])

          uids = imap.uid_fetch((lastseenuid + 1)..-1, 'FLAGS').
                 each_with_object([]) { |data, ret|
            uid, flags = data.attr.values_at('UID', 'FLAGS')
            seen[uidvalidity] = uid
            next if uid <= lastseenuid

            case is_unread
            when nil, !flags.include?(:Seen)
              ret << uid
            end
          }

          log pluralize(uids.size,
                        case is_unread
                        when true
                          'new unread mail'
                        when false
                          'new read mail'
                        else
                          'new mail'
                        end)

          next if uids.empty?

          imap.uid_fetch_mails(uids).each { |mail|
            yield mail, notified
          }
        }

        self.notified = notified
        self.lastseen = seen

        save!
      }
    ensure
      log 'Connection closed'
    end

    def mime_types
      interpolated['mime_types'] || %w[text/plain text/enriched text/html]
    end

    def lastseen
      Seen.new(memory['lastseen'])
    end

    def lastseen= value
      memory.delete('seen')  # obsolete key
      memory['lastseen'] = value
    end

    def make_seen
      Seen.new
    end

    def notified
      Notified.new(memory['notified'])
    end

    def notified= value
      memory['notified'] = value
    end

    private

    def glob_match?(pattern, value)
      File.fnmatch?(pattern, value, FNM_FLAGS)
    end

    def pluralize(count, noun)
      "%d %s" % [count, noun.pluralize(count)]
    end

    def event_headers_key
      super || 'headers'
    end

    class Client < ::Net::IMAP
      class << self
        def open(host, *args)
          imap = new(host, *args)
          yield imap
        ensure
          imap.disconnect unless imap.nil?
        end
      end

      attr_reader :uidvalidity

      def select(folder)
        ret = super(@folder = folder)
        @uidvalidity = responses['UIDVALIDITY'].last
        ret
      end

      def fetch(*args)
        super || []
      end

      def uid_fetch(*args)
        super || []
      end

      def uid_fetch_mails(set)
        uid_fetch(set, 'RFC822.HEADER').map { |data|
          Message.new(self, data, folder: @folder, uidvalidity: @uidvalidity)
        }
      end
    end

    class Seen < Hash
      def initialize(hash = nil)
        super()
        if hash
          # Deserialize a JSON hash which keys are strings
          hash.each { |uidvalidity, uid|
            self[uidvalidity.to_i] = uid
          }
        end
      end

      def []=(uidvalidity, uid)
        # Update only if the new value is larger than the current value
        if (curr = self[uidvalidity]).nil? || curr <= uid
          super
        end
      end
    end

    class Notified < Array
      def initialize(array = nil)
        super()
        replace(array) if array
      end

      def <<(value)
        slice!(0...-IDCACHE_SIZE) if size > IDCACHE_SIZE
        super
      end
    end

    class Message < SimpleDelegator
      DEFAULT_BODY_MIME_TYPES = %w[text/plain text/enriched text/html]
      DEFAULT_BODY_ATTACHMENT_MIME_TYPES = %w[image/jpeg image/png image/gif]

      attr_reader :uid, :folder, :uidvalidity

      module Scrubbed
        def scrubbed(method)
          (@scrubbed ||= {})[method.to_sym] ||=
            __send__(method).try(:scrub) { |bytes| "<#{bytes.unpack('H*')[0]}>" }
        end
      end

      include Scrubbed

      def initialize(client, fetch_data, props = {})
        @client = client
        props.each { |key, value|
          instance_variable_set(:"@#{key}", value)
        }
        attr = fetch_data.attr
        @uid = attr['UID']
        super(Mail.read_from_string(attr['RFC822.HEADER']))
      end

      def has_attachment?
        @has_attachment ||=
          if data = @client.uid_fetch(@uid, 'BODYSTRUCTURE').first
            struct_has_attachment?(data.attr['BODYSTRUCTURE'])
          else
            false
          end
      end

      def raw_mail
        @raw_mail ||=
          if data = @client.uid_fetch(@uid, 'BODY.PEEK[]').first
            data.attr['BODY[]']
          else
            ''
          end
      end

      def fetch
        @parsed ||= Mail.read_from_string(raw_mail)
      end

      def body_attachments(mime_types = DEFAULT_BODY_ATTACHMENT_MIME_TYPES)
        mail = fetch

        mail.attachments.select { |attachment| 
          if !mime_types.include?(attachment.mime_type)
            false
          else
            true
          end
        }
      end

      def body_parts(mime_types = DEFAULT_BODY_MIME_TYPES)
        mail = fetch
        if mail.multipart?
          mail.body.set_sort_order(mime_types)
          mail.body.sort_parts!
          mail.all_parts
        else
          [mail]
        end.select { |part|
          if part.multipart? || part.attachment? || !part.text? ||
             !mime_types.include?(part.mime_type)
            false
          else
            part.extend(Scrubbed)
            true
          end
        }
      end

      def mark_as_read
        @client.uid_store(@uid, '+FLAGS', [:Seen])
      end

      def delete
        @client.uid_store(@uid, '+FLAGS', [:Deleted])
        @client.expunge
      end

      private

      def struct_has_attachment?(struct)
        struct.multipart? && (
          struct.subtype == 'MIXED' ||
          struct.parts.any? { |part|
            struct_has_attachment?(part)
          }
        )
      end
    end


  end
end
