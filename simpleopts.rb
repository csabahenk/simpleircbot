require 'optparse'


######################################################################################


module SimpleOpts

  def self.get inopts, config_file_opt: nil, keep_config_file: false, argv: $*
    opts = {}
    [inopts].flatten.each { |oh|
      opts.merge! oh.map { |o,d| [o, {default: d}] }.to_h
    }
    fixer = proc { |a| { Fixnum => Integer }[a] || a }
    OptionParser.new { |op|
       opts.each { |o,w|
         # Mangling opts to OptionParser options in a disgraced manner
         # - opt_name: <scalar> becomes:
         #   op.on("-o", "--opt-name", fixer[<scalar>.class], <scalar>.to_s) {...}
         #   where fixer is needed to map arbitrary classes into the class set
         #   accepted by OptionParser
         # - opt_name: <class> becomes: op.on("-o", "--opt-name", <class>) {...}
         defval = w[:default]
         optargs = [
          "-#{o[0]}",
          "--#{o.to_s.gsub "_", "-"}=VAL",
          ((Class === defval ? [] : [defval.class]) << defval).instance_eval {|a|
             [fixer[a[0]], a[1..-1].map(&:to_s)].flatten
          }
         ].flatten
         op.on(*optargs) { |v| opts[o][:cmdline] = v }
       }
    }.parse! argv
    if config_file_opt
      config_file = (opts[config_file_opt]||{}).values_at(
         :cmdline, :default).compact.first
      keep_config_file or opts.delete(config_file_opt)
      unless config_file.to_s.empty?
        YAML.load_file(config_file).each { |k,v|
          (opts[k.to_sym]||{})[:conf] = v
        }
      end
    end
    opts.each { |o,w|
      v = w.values_at(:cmdline, :conf, :default).compact.first
      if Class === v
        puts "missing value for --#{o}"
        exit 1
      end
      v == "" and v = nil
      opts[o] = v
    }

    opts
  end

end
