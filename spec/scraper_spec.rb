# frozen_string_literal: true

require "tmpdir"

RSpec.describe Scraper do
  def fixture(name)
    File.read(File.join(__dir__, "fixtures", name))
  end

  def doc(name)
    Nokogiri::HTML(fixture(name))
  end

  def page(name, agent, url: "https://electorate.aec.gov.au/LocalitySearchResults.aspx")
    Mechanize::Page.new(URI(url), { "content-type" => "text/html" }, fixture(name), 200, agent)
  end

  def record(electorate, type: "current", locality: "CAMMERAY")
    { "state" => "NSW", "locality" => locality, "postcode" => "2062", "other_localities" => "",
      "electorate" => electorate, "electorate_type" => type, }
  end

  describe ".parse_electorates" do
    it "maps each electorate to the full URL of its localities" do
      electorates = described_class.parse_electorates(doc("electorates_page1.html"))
      expect(electorates.size).to eq(20)
      expect(electorates["Adelaide"])
        .to eq("https://electorate.aec.gov.au/LocalitySearchResults.aspx?filter=Adelaide&filterby=Electorate&divid=179")
    end
  end

  describe ".parse_localities" do
    it "saves one record for each electorate of a split locality" do
      expect(described_class.parse_localities(doc("postcode_2062.html")))
        .to eq([record("Bradfield"), record("Warringah")])
    end

    it "reads every locality on an electorate page" do
      records = described_class.parse_localities(doc("bradfield_page1.html"))
      expect(records.map { |r| r.values_at("locality", "postcode", "other_localities") }.uniq.size).to eq(20)
      expect(records).to all(include("state" => "NSW", "postcode" => /\A\d{4}\z/, "electorate_type" => "current"))
      expect(records.map { |r| r["electorate"] }).to include("Bradfield", "Warringah")
    end

    it "reads redistributed electorates as records of their own" do
      html = fixture("postcode_2062.html")
             .sub("<td></td><td>&nbsp;</td>", '<td><a href="#">Bennelong</a></td><td>CREMORNE</td>')
      expect(described_class.parse_localities(Nokogiri::HTML(html))).to eq(
        [record("Bradfield"), record("Warringah"), record("Bennelong", type: "redistributed")]
          .map { |r| r.merge("other_localities" => "CREMORNE") }
      )
    end

    it "raises when the results table is missing" do
      expect { described_class.parse_localities(Nokogiri::HTML("<html></html>")) }
        .to raise_error(Scraper::IncompleteData, /table not found/)
    end
  end

  describe ".next_page_postback" do
    it "finds the next numbered page" do
      expect(described_class.next_page_postback(doc("electorates_page1.html")))
        .to eq(["ctl00$ContentPlaceHolderBody$gridViewElectorates", "Page$2"])
      expect(described_class.next_page_postback(doc("bradfield_page1.html")))
        .to eq(["ctl00$ContentPlaceHolderBody$gridViewLocalities", "Page$2"])
    end

    it "follows the ... link to the next set of pages" do
      expect(described_class.next_page_postback(doc("electorates_page5.html")))
        .to eq(["ctl00$ContentPlaceHolderBody$gridViewElectorates", "Page$6"])
    end

    it "stops on the last page" do
      expect(described_class.next_page_postback(doc("electorates_page8.html"))).to be_nil
      expect(described_class.next_page_postback(doc("bradfield_page2.html"))).to be_nil
    end

    it "stops when the list fits on one page" do
      expect(described_class.next_page_postback(doc("postcode_2062.html"))).to be_nil
    end
  end

  describe ".validate!" do
    let(:localities) do
      { "Bradfield" => [record("Bradfield"), record("Warringah")], "Warringah" => [record("Warringah")] }
    end

    before { allow($stdout).to receive(:puts) }

    it "returns every record once, though a split locality is on each electorate's page" do
      expect(described_class.validate!(localities)).to eq([record("Bradfield"), record("Warringah")])
    end

    it "raises when an electorate has no localities" do
      expect { described_class.validate!(localities.merge("Warringah" => [])) }
        .to raise_error(Scraper::IncompleteData, /No localities found for Warringah/)
    end

    it "raises when a current electorate isn't in the list" do
      localities["Bradfield"] << record("BradfieldWarringah")
      expect { described_class.validate!(localities) }
        .to raise_error(Scraper::IncompleteData, /not in the list: BradfieldWarringah/)
    end

    it "allows redistributed electorates that aren't in the list yet" do
      localities["Bradfield"] << record("Newtown", type: "redistributed")
      expect(described_class.validate!(localities).size).to eq(3)
    end

    it "raises when an electorate isn't on its own page" do
      localities["Warringah"] = [record("Bradfield")]
      expect { described_class.validate!(localities) }
        .to raise_error(Scraper::IncompleteData, /missing from their own pages: Warringah/)
    end

    it "warns about postcodes that aren't 4 digits" do
      localities["Warringah"] << record("Warringah").merge("postcode" => "62")
      expect { described_class.validate!(localities) }.to output(/1 postcodes aren't 4 digits: 62/).to_stdout
    end
  end

  describe "paging" do
    let(:scraper) { described_class.new }
    let(:submitted) { [] }

    def pages(url)
      [].tap { |seen| scraper.send(:each_page, url) { |p| seen << p } }
    end

    it "posts the form back for each following page" do
      allow_any_instance_of(Mechanize).to receive(:get) { |agent, _url| page("bradfield_page1.html", agent) }
      allow_any_instance_of(Mechanize).to receive(:submit) do |agent, form|
        submitted << form
        page("bradfield_page2.html", agent)
      end

      expect(pages("https://example.com").size).to eq(2)
      expect(submitted.map { |f| [f["__EVENTTARGET"], f["__EVENTARGUMENT"]] })
        .to eq([["ctl00$ContentPlaceHolderBody$gridViewLocalities", "Page$2"]])
      expect(submitted.first["__VIEWSTATE"]).not_to be_empty
    end

    it "raises when the site doesn't move to the next page" do
      allow_any_instance_of(Mechanize).to receive(:get) { |agent, _url| page("bradfield_page1.html", agent) }
      allow_any_instance_of(Mechanize).to receive(:submit) { |agent, _form| page("bradfield_page1.html", agent) }

      expect { pages("https://example.com") }
        .to raise_error(Scraper::IncompleteData, /Asked for page 2 of https:..example.com but got 1/)
    end
  end

  describe "saving" do
    around do |example|
      Dir.mktmpdir do |dir|
        Dir.chdir(dir) { example.run }
      ensure
        ScraperWiki.close_sqlite
      end
    end

    it "replaces the previous run's data" do
      scraper = described_class.new
      scraper.send(:save, [record("North Sydney"), record("Warringah")])
      scraper.send(:save, [record("Bradfield"), record("Warringah")])

      expect(ScraperWiki.select("electorate FROM data ORDER BY electorate").map { |r| r["electorate"] })
        .to eq(%w[Bradfield Warringah])
    end
  end
end
