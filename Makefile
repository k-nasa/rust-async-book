fmt:
	prettier --write **/*.md
all:
	rm ./all.md && ruby make_all.rb
count:
	rm ./all.md && ruby make_all.rb && wc -m all.md
