require "json"

# Assertion helpers shared by the Ruby integration scripts.
module TestReport
  def self.run(&block)
    @checks = 0
    @failures = []
    instance_eval(&block)
    @failures.each do |name, error|
      puts "not ok - #{name}"
      puts "    #{error.class}: #{error.message}"
    end
    if @failures.empty?
      puts "#{@checks} checks passed"
      exit 0
    else
      warn "#{@failures.length} of #{@checks} checks failed"
      exit 1
    end
  end

  def self.check(name)
    @checks += 1
    yield
    puts "ok - #{name}"
  rescue StandardError => error
    @failures << [name, error]
  end

  def self.assert(condition, message)
    raise message unless condition
  end
end
