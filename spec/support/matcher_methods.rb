# frozen_string_literal: true
require 'pp'

RSpec::Matchers.define :have_A_record do |relrrname, address|
  match do |actual|
    actual.any? do |rr|
      rr.data.class == Resolv::DNS::Resource::IN::A &&
        (relrrname.nil? || rr.name == relrrname) &&
        (address.nil? || rr.data.address.to_s == address)
    end
  end

  failure_message do |actual|
    "expected #{actual.pretty_inspect} to have a record '#{relrrname} A #{address}'"
  end
end

RSpec::Matchers.define :have_AAAA_record do |relrrname, address|
  match do |actual|
    actual.any? do |rr|
      rr.data.class == Resolv::DNS::Resource::IN::AAAA &&
        (relrrname.nil? || rr.name == relrrname) &&
        (address.nil? || rr.data.address.to_s == address.upcase)
    end
  end

  failure_message do |actual|
    "expected #{actual.pretty_inspect} to have a record '#{relrrname} AAAA #{address}'"
  end
end

RSpec::Matchers.define :have_PTR_record do |relrrname, dname|
  match do |actual|
    actual.any? do |rr|
      rr.data.class == Resolv::DNS::Resource::IN::PTR &&
        (relrrname.nil? || rr.name == relrrname) &&
        (dname.nil? || rr.data.name.to_s == dname)
    end
  end

  failure_message do |actual|
    "expected #{actual.pretty_inspect} to have a record '#{relrrname} PTR #{dname}'"
  end
end

RSpec::Matchers.define :have_TXT_record do |relrrname, strings|
  match do |actual|
    actual.any? do |rr|
      rr.data.class == Resolv::DNS::Resource::IN::TXT &&
        (relrrname.nil? || rr.name == relrrname) &&
        (strings.nil? || rr.data.strings == strings)
    end
  end

  failure_message do |actual|
    "expected #{actual.pretty_inspect} to have a record '#{relrrname} TXT #{strings.map { |s| "\"#{s}\"" }.join(" ")}'"
  end
end

RSpec::Matchers.define :have_SRV_record do |relrrname, data|
  def srv_data(rrdata)
    "#{rrdata.priority} #{rrdata.weight} #{rrdata.port} #{rrdata.target.to_s}"
  end

  match do |actual|
    actual.any? do |rr|
      rr.data.class == Resolv::DNS::Resource::IN::SRV &&
        (relrrname.nil? || rr.name == relrrname) &&
        (data.nil? || srv_data(rr.data) == data)
    end
  end

  failure_message do |actual|
    "expected #{actual.pretty_inspect} to have a record '#{relrrname} SRV #{data}'"
  end
end

RSpec::Matchers.define :have_CNAME_record do |relrrname, dname|
  match do |actual|
    actual.any? do |rr|
      rr.data.class == Resolv::DNS::Resource::IN::CNAME &&
        (relrrname.nil? || rr.name == relrrname) &&
        (dname.nil? || rr.data.name.to_s == dname)
    end
  end

  failure_message do |actual|
    "expected #{actual.pretty_inspect} to have a record '#{relrrname} CNAME #{dname}'"
  end
end
