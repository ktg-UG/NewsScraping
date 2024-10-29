require 'selenium-webdriver'
require 'nokogiri'
require 'openai'

class ArticlesSummaryController < ApplicationController
  def index
    @articles = Rails.cache.fetch('articles', expires_in: 1.hour) { [] }
    #articlesが空かを確認
    #Rails.logger.info("1,@articles: #{@articles.inspect}")
  end

  def scrape
    url = params[:url]

    articles = Rails.cache.fetch('articles', expires_in: 1.hour) { [] }
    existing_article = articles.find { |article| article[:url] == url}

    if existing_article
      flash[:notice] = "このURLの情報はすでに保存されています"
      return redirect_to action: :index
    end

    options = Selenium::WebDriver::Chrome::Options.new
    options.add_argument('--headless')
    options.add_argument('--disable-gpu')
    options.add_argument('--no-sandbox')
    options.add_argument('--disable-dev-shm-usage')


    driver = Selenium::WebDriver.for :chrome, options: options

    begin
      driver.navigate.to url
      html = driver.page_source
      doc = Nokogiri::HTML(html)

      title = doc.css('h1').text.strip
      date = doc.css('p.content--date time').text.strip
      content = doc.css('div.body-text p').map(&:text).join("\n").strip

          # タイトル、日付、本文のいずれかが空の場合はエラーを返す
      if title.empty? || date.empty? || content.empty?
        flash[:notice] = "URLが間違っています。正しいURLを入力してください。"
        return redirect_to action: :index
      end

      raise "OpenAI APIキーが設定されていません" unless ENV['OPENAI_API_KEY']
      client = OpenAI::Client.new(access_token: ENV['OPENAI_API_KEY'])

      summary_prompt = "以下のニュース記事を50字程度で要約してください: \n\n#{content}"
      begin
        summary_response = client.chat(
          parameters: {
            model: "gpt-3.5-turbo",
            messages: [{role: "user", content: summary_prompt}],
            max_tokens: 300,
          }
        )
        summary = summary_response.dig("choices", 0, "message", "content")
      rescue => e
        summary = "サマリーの生成に失敗しました : #{e.message}"
      end

      risk_score_prompt = "ニュース記事の内容に基づき、記事の重要度を1-100で評価してください。評価基準は、日本経済に与える影響です。数値のみを出力してください。\n\n#{content}"
      begin
          risk_score_response = client.chat(
            parameters: {
              model: "gpt-3.5-turbo",
              messages: [{role: "user", content: risk_score_prompt}],
              max_tokens: 50,
            }
          )
          risk_score = risk_score_response.dig("choices", 0, "message", "content")
      rescue => e
        Rails.logger.error("OpenAI API Error: #{e.message}")
        risk_score = "リスクスコアの生成に失敗しました : #{e.message}"
      end
      @article = { url: url, title: title, date: date, content: content, summary: summary, risk_score: risk_score}

      #Rails.logger.info("1,articles: #{articles.inspect}")
      articles.unshift(@article)
      #Rails.logger.info("2,articles: #{articles.inspect}")
      Rails.cache.write('articles', articles, expires_in: 1.hour)
      #Rails.logger.info("Cache updated with new article: #{@article.inspect}")
      #Rails.logger.info("Updated cache contents: #{articles.inspect}")
    rescue => e
      @error = "ページの取得に失敗しました : #{e.message}"
    ensure
      driver.quit
    end
    redirect_to action: :index
  end

  def clear
    Rails.cache.clear
    flash[:notice] = "キャッシュが削除されました"
    redirect_to action: :index
  end

end