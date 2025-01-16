iac:
	sam deploy --resolve-image-repos

iac-validate:
	sam validate --lint -t template.json

test-s3-event:
	sam local invoke OnImportFunction --event events/s3-event.json

.PHONY: iac iac-validate test-s3-event
