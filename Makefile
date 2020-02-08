fmt:
	prettier --write **/*.md
all_text:
	rm ./all.md && ruby make_all.rb
