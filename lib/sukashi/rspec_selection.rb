# Loaded inside RSpec. Retain the job's original file list, tags and filters.
require "json"
ids = JSON.parse(File.read(ENV.fetch("SUKASHI_SELECT"))).to_h { |id| [id, true] }
RSpec.configure do |config|
  config.define_derived_metadata do |metadata|
    if metadata.key?(:execution_result)
      metadata[:sukashi_excluded] = !ids.key?(RSpec::Core::Metadata.id_from(metadata))
    end
  end
  config.filter_run_excluding(sukashi_excluded: true)
end
