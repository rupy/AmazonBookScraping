# coding: utf-8

require "./scraping"

ASSOCIATE_TAG = "********"
ACCESS_KEY = "********"
SECRET_KEY = "********" 
scraping = AmazonBookScraping.new(ASSOCIATE_TAG, ACCESS_KEY, SECRET_KEY)

# 全ページ数を取得
puts scraping.total_pages("ruby")

# ASINを取得
puts scraping.get_asin("ruby")

# 和書に対して再帰的にカテゴリ名を取得する
puts scraping.get_browsenode_info("465392")
