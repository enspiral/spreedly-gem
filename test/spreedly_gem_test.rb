require 'rubygems'
require 'test/unit'
require 'shoulda'
require 'yaml'
require 'pp'

if ENV["SPREEDLY_TEST"] == "REAL"
  require 'spreedly'
  require 'spreedly/test_hacks'
else
  require 'spreedly/mock'
end

test_site = YAML.load(File.read(File.dirname(__FILE__) + '/test_site.yml'))
Spreedly.configure(test_site['name'], test_site['token'])


class SpreedlyGemTest < Test::Unit::TestCase
  def self.only_real
    yield if ENV["SPREEDLY_TEST"] == "REAL"
  end

  context "A Spreedly site" do
    setup do
      Spreedly::Subscriber.wipe!
    end

    should "delete a subscriber" do
      one = create_subscriber
      two = create_subscriber
      subscribers = Spreedly::Subscriber.all
      assert subscribers.size == 2
      Spreedly::Subscriber.delete!(one.id)
      subscribers = Spreedly::Subscriber.all
      assert subscribers.size == 1
      assert_equal two.id, subscribers.first.id
    end

    context "payment api" do
      context "creating an invoice" do
        setup do
          @regular_plan = find_plan("Test Regular Plan")
        end

        should "accept subscriber attributes" do
          customer_id = "33"
          Spreedly::Invoice.create!(@regular_plan.id, :subscriber => { :customer_id => customer_id, :email => "how@hot.com", :screen_name => "Money Giva!"})
          assert_equal "Money Giva!", Spreedly::Subscriber.find(customer_id).screen_name
        end

        should "create a subscriber" do
          customer_id = "33"
          invoice = create_invoice(@regular_plan.id, customer_id)
          assert_equal customer_id, invoice.subscriber.id
        end

        should "generate an invoice token" do
          customer_id = "33"
          invoice = create_invoice(@regular_plan.id, customer_id)
          assert_not_nil invoice.token
        end

        should "generate an open invoice" do
          customer_id = "33"
          invoice = create_invoice(@regular_plan.id, customer_id)
          assert !invoice.closed?
        end

        should "add invoice to existing subscriber" do
          subscriber = Spreedly::Subscriber.create!('joe')
          invoice = create_invoice(@regular_plan.id, subscriber.id)
          assert_equal subscriber.id, invoice.subscriber.id
        end

        should "have 1 line item when first subscribing to a plan" do
          customer_id = "33"
          invoice = create_invoice(@regular_plan.id, customer_id)
          assert_equal 1, invoice.line_items.size
        end

        should "expose attributes of line items" do
          customer_id = "33"
          invoice = create_invoice(@regular_plan.id, customer_id)
          line_item = invoice.line_items.first
          assert_kind_of BigDecimal, line_item.amount
          assert_kind_of String, line_item.description
        end

        should "have 2 line items when upgrading/downgrading to different feature levels" do
          @plus_plan = find_plan("Test Plus Plan")
          assert_not_equal @plus_plan.feature_level, @regular_plan.feature_level, "For this test to pass, the feature levels must be different for the two plans."

          customer_id              = "33"
          invoice_for_regular_plan = create_invoice(@regular_plan.id, customer_id)
          assert_equal 1, invoice_for_regular_plan.line_items.size
          invoice_for_regular_plan.pay(credit_card)

          invoice_for_plus_plan = create_invoice(@plus_plan.id, customer_id)
          assert_equal 2, invoice_for_plus_plan.line_items.size
        end

        should "raise error when no subscription plan exists" do
          customer_id = 33
          plan_id     = 1000000000
          ex = assert_raise(RuntimeError) do 
            invoice = create_invoice(plan_id, customer_id)
          end

          assert_match /the subscription plan does not exist/i, ex.message
        end

        should "raise error when passing invalid request elements" do
          customer_id = 33
          ex = assert_raise(RuntimeError) do 
            invoice = create_invoice(@regular_plan.id, customer_id, :extra_invalid_element => "hey")
          end

          assert_match /extra_invalid_element/i, ex.message
        end
      end

      context "paying an invoice" do
        setup do
          @regular_plan = find_plan("Test Regular Plan")
        end

        should "close invoice" do
          customer_id = "33"
          invoice = create_invoice(@regular_plan.id, customer_id)
          invoice.pay(credit_card)
          assert invoice.closed?
        end

        should "be able to pay using invoice token" do
          customer_id = "33"
          invoice = create_invoice(@regular_plan.id, customer_id)
          assert !Spreedly::Subscriber.find(customer_id).active?
          Spreedly::Invoice.pay(credit_card, invoice.token)
          assert Spreedly::Subscriber.find(customer_id).active?
        end

        should "activate subscriber" do
          customer_id = "33"
          invoice = create_invoice(@regular_plan.id, customer_id)

          assert !invoice.subscriber.active?

          invoice.pay(credit_card)

          assert invoice.subscriber.active?
        end

        should "raise RetryError when there are errors in fields" do
          customer_id = "33"
          invoice = create_invoice(@regular_plan.id, customer_id)
          ex = assert_raise(Spreedly::RetryError) do
            invoice.pay(:number => "411111111111")
          end
          assert_match /Payment verification failed./i, ex.message
          assert_equal 9, ex.errors.size
        end

        should "raise error when payment fails verification" do
          customer_id = "33"
          invoice = create_invoice(@regular_plan.id, customer_id)
          ex = assert_raise(RuntimeError) do
            invoice.pay(credit_card(:unauthorized))
          end
          assert_match /Charge not authorized/i, ex.message
        end
        
        should "raise RetryError when gateway times out" do
          customer_id = "33"
          invoice = create_invoice(@regular_plan.id, customer_id)
          ex = assert_raise(Spreedly::RetryError) do
            invoice.pay(credit_card(:gw_unavailable))
          end
          assert_match /A timeout has occured which prevented your payment from t/i, ex.message
          assert ex.errors.empty?
        end

        should "raise error if invoice can't be found with given token" do
          customer_id = "33"
          invoice = create_invoice(@regular_plan.id, customer_id)

          #override token, so we can't find it on system
          def invoice.token
            "iloveruby"
          end

          ex = assert_raise(RuntimeError) do
            invoice.pay(credit_card)
          end

          assert_match /Unable to find invoice/i, ex.message
        end
      end
    end

    context "adding a subscriber" do
      should "generate a token" do
        subscriber = Spreedly::Subscriber.create!('joe')
        assert_not_nil subscriber.token
        assert_equal subscriber.token, Spreedly::Subscriber.find('joe').token
      end
    
      should "accept email address as an argument" do
        subscriber = Spreedly::Subscriber.create!('joe', 'a@b.cd')
        assert_equal 'a@b.cd', Spreedly::Subscriber.find('joe').email
      end

      should "accept screen name as an argument" do
        subscriber = Spreedly::Subscriber.create!('joe', 'a@b.cd', 'tuna')
        assert_equal 'tuna', Spreedly::Subscriber.find('joe').screen_name
      end

      should "accept optional arguments: like billing first name" do
        subscriber = Spreedly::Subscriber.create!('joe', {:billing_first_name => 'Joe'})
        assert_equal 'Joe', Spreedly::Subscriber.find('joe').billing_first_name
      end
    end # adding a subscriber
    
    should "update subscriber" do
      subscriber = Spreedly::Subscriber.create!('joe', :screen_name => "big-joe")
      assert_equal "big-joe", Spreedly::Subscriber.find(subscriber.id).screen_name
      subscriber.update(:screen_name => "small-joe")
      assert_equal "small-joe", Spreedly::Subscriber.find(subscriber.id).screen_name
    end
    
    should "get a subscriber" do
      id = create_subscriber.id
      subscriber = Spreedly::Subscriber.find(id)
      assert_nil subscriber.active_until
    end
    
    should "return nil when getting a subscriber that does NOT exist" do
      assert_nil Spreedly::Subscriber.find("junk")
    end
    
    should "expose and parse attributes" do
      subscriber = create_subscriber('bob')
      assert_kind_of Time, subscriber.created_at
      assert !subscriber.active
      assert !subscriber.recurring
      assert_equal BigDecimal('0.0'), subscriber.store_credit
    end
    
    should "raise error if subscriber exists" do
      create_subscriber('bob')
      ex = assert_raise(RuntimeError) do
        create_subscriber('bob')
      end
      assert_match(/exists/i, ex.message)
    end
    
    should "raise error if subscriber is invalid" do
      ex = assert_raise(RuntimeError) do
        create_subscriber('')
      end
      assert_match(/customer id can't be blank/i, ex.message)
    end
    
    should "create with additional params" do
      subscriber = create_subscriber("fred", "fred@example.com", "FREDDY")
      assert_equal "FREDDY", subscriber.screen_name
      assert_equal "fred@example.com", subscriber.email
    end
    
    should "return all subscribers" do
      one = create_subscriber
      two = create_subscriber
      subscribers = Spreedly::Subscriber.all
      assert subscribers.size >= 2
      assert subscribers.detect{|e| e.id == one.id}
      assert subscribers.detect{|e| e.id == two.id}
    end
    
    should "generate a subscribe url" do
      assert_equal "https://spreedly.com/#{Spreedly.site_name}/subscribers/joe/subscribe/1/Joe%20Bob",
        Spreedly.subscribe_url('joe', '1', "Joe Bob")
      assert_equal "https://spreedly.com/#{Spreedly.site_name}/subscribers/joe/subscribe/1/",
        Spreedly.subscribe_url('joe', '1')
    end
    
    should "generate a pre-populated subscribe url" do
      assert_equal "https://spreedly.com/#{Spreedly.site_name}/subscribers/joe/subscribe/1?email=joe.bob@test.com&first_name=Joe&last_name=Bob",
        Spreedly.subscribe_url('joe', '1', :email => "joe.bob@test.com", :first_name => "Joe", :last_name => "Bob")
      assert_equal "https://spreedly.com/#{Spreedly.site_name}/subscribers/joe/subscribe/1?first_name=Joe&last_name=Bob",
        Spreedly.subscribe_url('joe', '1', :first_name => "Joe", :last_name => "Bob")
      assert_equal "https://spreedly.com/#{Spreedly.site_name}/subscribers/joe/subscribe/1?return_url=http://stuffo.example.com",
        Spreedly.subscribe_url('joe', '1', :return_url => 'http://stuffo.example.com')
    end
    
    should "generate an edit subscriber url" do
      assert_equal "https://spreedly.com/#{Spreedly.site_name}/subscriber_accounts/zetoken",
        Spreedly.edit_subscriber_url('zetoken')
      assert_equal "https://spreedly.com/#{Spreedly.site_name}/subscriber_accounts/zetoken?return_url=http://stuffo.example.com",
        Spreedly.edit_subscriber_url('zetoken', 'http://stuffo.example.com')
    end
    
    should "comp an inactive subscriber" do
      sub = create_subscriber
      assert !sub.active?
      assert_nil sub.active_until
      assert_equal "", sub.feature_level
      sub.comp(1, 'days', 'Sweet!')
      sub = Spreedly::Subscriber.find(sub.id)
      assert_not_nil sub.active_until
      assert_equal 'Sweet!', sub.feature_level
      assert sub.active?
    end
    
    should "comp an active subscriber" do
      sub = create_subscriber
      assert !sub.active?
      sub.comp(1, 'days', 'Sweet!')

      sub = Spreedly::Subscriber.find(sub.id)
      assert sub.active?
      old_active_until = sub.active_until
      sub.comp(1, 'days')

      sub = Spreedly::Subscriber.find(sub.id)
      assert sub.active?
      assert old_active_until < sub.active_until
    end
    
    should "throw an error if comp is against unknown subscriber" do
      sub = create_subscriber
      Spreedly::Subscriber.wipe!
      ex = assert_raise(RuntimeError) do
        sub.comp(1, 'days', 'bogus')
      end
      assert_match(/exists/i, ex.message)
    end
    
    should "throw an error if comp is invalid" do
      sub = create_subscriber
      ex = assert_raise(RuntimeError) do
        sub.comp(nil, nil, 'bogus')
      end
      assert_match(/validation/i, ex.message)
      assert_raise(RuntimeError){sub.comp(1, nil)}
      assert_raise(RuntimeError){sub.comp(nil, 'days')}
    end
    
    should "return subscription plans" do
      assert !Spreedly::SubscriptionPlan.all.empty?
      assert_not_nil Spreedly::SubscriptionPlan.all.first.name
    end
    
    should "return the subscription plan id" do
      plan = Spreedly::SubscriptionPlan.all.first
      assert_not_equal plan.id, plan.object_id
    end
    
    should "be able to find an individual subscription plan" do
      plan = Spreedly::SubscriptionPlan.all.first
      assert_equal plan.name, Spreedly::SubscriptionPlan.find(plan.id).name
    end
    
    context "with a Free Trial plan" do
      setup do
        @trial = Spreedly::SubscriptionPlan.all.detect{|e| e.name == "Test Free Trial Plan" && e.trial?}
        assert @trial, "For this test to pass in REAL mode you must have a trial plan in your Spreedly test site with the name \"Test Free Trial Plan\"."
      end
      
      should "be able to activate free trial" do
        sub = create_subscriber
        assert !sub.active?
        assert !sub.on_trial?
        
        sub.activate_free_trial(@trial.id)
        sub = Spreedly::Subscriber.find(sub.id)
        assert sub.active?
        assert sub.on_trial?
      end
      
      should "throw an error if a second trial is activated" do
        sub = create_subscriber
        sub.activate_free_trial(@trial.id)
        ex = assert_raise(RuntimeError){sub.activate_free_trial(@trial.id)}
        assert_match %r{not eligible}, ex.message
      end
      
      should "allow second trial if 'allow_free_trial' is excecuted" do
        sub = create_subscriber
        sub.activate_free_trial(@trial.id)
        sub.allow_free_trial
        sub.activate_free_trial(@trial.id)
        sub = Spreedly::Subscriber.find(sub.id)
        assert sub.active?
        assert sub.on_trial?
      end
      
      should "throw errors on invalid free trial activation" do
        sub = create_subscriber
        
        ex = assert_raise(RuntimeError){sub.activate_free_trial(0)}
        assert_match %r{no longer exists}, ex.message

        ex = assert_raise(RuntimeError){sub.activate_free_trial(nil)}
        assert_match %r{missing}, ex.message
      end
    end
    
    context "with a Regular plan" do
      setup do
        @regular_plan = Spreedly::SubscriptionPlan.all.detect{|e| e.name == "Test Regular Plan"}
        assert @regular_plan, "For this test to pass in REAL mode you must have a regular plan in your Spreedly test site with the name \"Test Regular Plan\". It must be an auto-recurring plan."
      end

      should "stop auto renew for subscriber" do
        subscriber = create_subscriber
        subscriber.subscribe(@regular_plan.id)
        
        subscriber = Spreedly::Subscriber.find(subscriber.id)
        assert subscriber.active?
        assert subscriber.recurring

        subscriber.stop_auto_renew
        subscriber = Spreedly::Subscriber.find(subscriber.id)
        assert subscriber.active?
        assert !subscriber.recurring
      end
    end
    
    context "adding fees" do
      
      setup do
        @regular_plan = Spreedly::SubscriptionPlan.all.detect{|e| e.name == "Test Regular Plan"}
        assert @regular_plan, "For this test to pass in REAL mode you must have a regular plan in your Spreedly test site with the name \"Test Regular Plan\". It must be an auto-recurring plan."
      end
      
      should "be able to add fee to user" do
        sub = create_subscriber
        sub.subscribe(@regular_plan.id)
        sub.add_fee(:name => "Daily Bandwidth Charge", :amount => "2.34", :description => "313 MB used", :group => "Traffic Fees")
      end
    
      should "throw an error when add fee to not active user" do
        sub = create_subscriber
        ex = assert_raise(RuntimeError) do 
          sub.add_fee(:name => "Daily Bandwidth Charge", :amount => "2.34", :description => "313 MB used", :group => "Traffic Fees")
        end
        assert_match %r{Unprocessable Entity}, ex.message
      end
    
      should "throw an error when add fee with incomplete arguments" do
        sub = create_subscriber
        sub.subscribe(@regular_plan.id)
        ex = assert_raise(RuntimeError) do 
          sub.add_fee(:name => "Daily Bandwidth Charge", :description => "313 MB used", :group => "Traffic Fees")
        end
        assert_match %r{Unprocessable Entity}, ex.message        
      end
    end
    
    should "throw an error if stopping auto renew on a non-existent subscriber" do
      sub = Spreedly::Subscriber.new('customer_id' => 'bogus')
      ex = assert_raise(RuntimeError){sub.stop_auto_renew}
      assert_match %r{does not exist}, ex.message
    end

    only_real do
      should "throw an error if comp is wrong type" do
        sub = create_subscriber
        sub.comp(1, 'days', 'something')
        ex = assert_raise(RuntimeError) do
          sub.comp(1, 'days', 'something')
        end
        assert_match(/invalid/i, ex.message)
      end
    end
  end
  
  def create_subscriber(id=(rand*100000000).to_i, email=nil, screen_name=nil)
    Spreedly::Subscriber.create!(id, email, screen_name)
  end
<<<<<<< HEAD
=======

  def create_invoice(plan_id, customer_id, extra_options = {})
    Spreedly::Invoice.create!(plan_id, :subscriber => { :customer_id => customer_id, :email => "how@hot.com"}.merge(extra_options))
  end

  def credit_card(type = :good)
    number = case type
    when :good
      "4222222222222"
    when :unauthorized
      "4012888888881881"
    when :gw_unavailable
      "4111111111111111"
    else
      raise "Expected either :good, unauthorized, or :gw_unavailable."
    end
    {
      :number => number, 
      :verification_value => "234", 
      :month => "11", 
      :year => "2010", 
      :first_name => "Fred", 
      :last_name => "Mogul",
      :card_type => "visa"
    }
  end

  def find_plan(name)
    @all_plans ||= Spreedly::SubscriptionPlan.all
    plan = @all_plans.detect { |e| e.name == name }
    assert plan, "For this test to pass in REAL mode you must have a plan named #{name}"
    plan
  end
>>>>>>> 3fce9a3026df521b5cc16f7a55ec6df5430301d4
end
