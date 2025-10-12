package jiracloud;

use strict;
use warnings;
use Data::Dumper;
use LWP::UserAgent;
use HTTP::Cookies::Netscape;
use JSON;
use MIME::Base64;
use HTTP::Request::Common qw(POST);

my $ua;
my $meta;

$Data::Dumper::Indent = 1;



sub new {
	my $class = shift;
	my %arg = @_;

	# --- 1. Basic Setup & Object Creation ---
	die "No URL defined for Jira object" unless $arg{Url};

	my $ua = LWP::UserAgent->new;
	my $self = bless {
		ua       => $ua,
		url      => $arg{Url},
		login    => $arg{Login},
		password => $arg{Password},
		project  => $arg{Project},
		base64   => $arg{Base64},
		verbose  => $arg{Verbose} || 0,
		meta     => {}, # Initialize meta as an empty hash reference
	}, $class;

	# --- 2. Authentication ---
	# Set the default authorization header for all subsequent requests
	my $basic = $arg{Base64}; 
	$self->{ua}->default_header('Authorization' => "Basic $basic");

	# --- 3. Login Check ---

	my $res = $self->{ua}->get($self->{url} . '/rest/api/2/myself');

	unless ($res->is_success) {
		die "Jira login failed: " . $res->status_line . " - " . $res->decoded_content . "\n";
	}
	print "Logged in to Jira successfully as '$self->{login}'\n" if $self->{verbose};

	# --- 4. Metadata Fetching (The missing piece) ---
	# This code now runs *after* the successful login check.
	if ($arg{Project}) {
		print "Fetching metadata for project '$arg{Project}'...\n" if $self->{verbose};
        
  
		my $meta_url = $self->{url} . '/rest/api/2/issue/createmeta?projectKeys=' . $arg{Project} . '&expand=projects.issuetypes.fields';
		my $response = $self->{ua}->get($meta_url);

		if ($response->is_success) {
			my $rawMeta = decode_json($response->decoded_content);
			
        
			my $meta = {
				fields     => {},
				fieldtypes => {},
			};
      
			foreach my $project (@{$rawMeta->{projects}}) {
				next unless $project->{key} eq $arg{Project};
				foreach my $issuetype (@{$project->{issuetypes}}) {
					foreach my $fieldId (keys %{$issuetype->{fields}}) {
						my $field_data = $issuetype->{fields}->{$fieldId};
						my $field_name = $field_data->{name};
						
						# Store the mapping of Name -> ID for the given issue type
						$meta->{fields}->{$issuetype->{name}}->{$field_name} = $fieldId;
						
						# Store the mapping of Name -> Type (e.g., 'string', 'datetime')
						$meta->{fieldtypes}->{$field_name} = $field_data->{schema}->{type};
					}
				}
			}
			
            # Assign the populated local hash to the object's meta property
			$self->{meta} = $meta;
			print "Metadata successfully fetched and parsed.\n" if $self->{verbose};
            # print Dumper($self->{meta}) if $self->{verbose}; # You can un-comment this to see the full meta structure

		} else {
			die "Could not get metadata for project '$arg{Project}': " . $response->status_line . "\n";
		}
	}

	# --- 5. Return the fully initialized object ---
	return $self;
}

sub getMeta {
	my $self = shift;
	return $self->{meta};
}

sub getUser {
	my $self = shift;
	my %arg = @_;
	# Note: For 'Id', you must use the Atlassian Account ID (accountId)
	my $response = $self->{ua}->get($self->{url} . '/rest/api/3/user?accountId=' . $arg{Id});
	if ($response->is_success) {
		return decode_json($response->decoded_content);
	}
	return;
}

sub getAllIssues {
	my $self = shift;
	my %arg = @_;
	# Note: maxResults has a default and maximum defined by Jira Cloud (usually 100)
	my $max_results = $arg{Max} || 100;
	my $response = $self->{ua}->get($self->{url} . '/rest/api/3/search?maxResults=' . $max_results . '&jql=project="' . $arg{Project} . '"');
	if ($response->is_success) {
		return decode_json($response->decoded_content);
	} else {
		print "Error getting issues: " . $response->status_line . "\n";
		return;
	}
}

sub getAllLinkTypes {
	my $self = shift;
	my $response = $self->{ua}->get($self->{url} . '/rest/api/3/issueLinkType');
	if ($response->is_success) {
		return \@{decode_json($response->decoded_content)->{issueLinkTypes}};
	} else {
		print "Error getting link types: " . $response->status_line . "\n";
		return;
	}
}

sub getFields {
    my $self = shift;
    my %arg = @_;
    my $basic = $arg{Base64};


    # Uncomment the next line if you have issues
    # use Data::Dumper;

    # This endpoint reveals fields available when creating an issue in a project.
    my $url = $self->{url} . "/rest/api/2/issue/createmeta?projectKeys=" . $self->{project} . "&expand=projects.issuetypes.fields";

    my $request = HTTP::Request->new(GET => $url);
    $request->header('Authorization' => "Basic $self->{base64}");

    print "Fetching create metadata to find available fields for project '$self->{project}'...\n" if $self->{verbose};

    my $response = $self->{ua}->request($request);

    unless ($response->is_success) {
        warn "Failed to get createmeta from Jira: " . $response->status_line;
        warn $response->decoded_content if $self->{verbose};
        return; # Return undef on failure
    }

    my $data = decode_json($response->decoded_content);

    # --- ROBUST PARSING LOGIC ---
    my %fields; # Use a hash to automatically handle duplicates

    # Check if the 'projects' array exists and is not empty
    unless ($data->{projects} && ref $data->{projects} eq 'ARRAY' && @{$data->{projects}}) {
        warn "Jira API response did not contain any project data for project key '$self->{project}'. Check permissions or project key.";
        # Uncomment the line below to see the exact JSON response from Jira
        # warn "JIRA RESPONSE:\n" . Dumper($data);
        return;
    }

    # Iterate over ALL projects returned
    foreach my $project (@{$data->{projects}}) {
        # Iterate over ALL issue types within each project
        foreach my $issuetype (@{$project->{issuetypes}}) {
            # The fields are in a hash where keys are the field IDs
            foreach my $field_id (keys %{$issuetype->{fields}}) {
                my $field_data = $issuetype->{fields}->{$field_id};
                # Use the field's name as the key to prevent duplicates
                $fields{$field_data->{name}} = {
                    id   => $field_id,
                    name => $field_data->{name}
                };
            }
        }
    }



    # Convert the hash of fields back into an array, which the main script expects.
    my @field_list = values %fields;

    if (!@field_list) {
         warn "Warning: Found 0 fields for project '$self->{project}'. Check if the project has configured issue types and fields.";
    }

    return \@field_list;
}

sub getAllPriorities {
	my $self = shift;
	my $response = $self->{ua}->get($self->{url} . '/rest/api/3/priority');
	if ($response->is_success) {
		return \@{decode_json($response->decoded_content)};
	} else {
		print "Error getting priorities: " . $response->status_line . "\n";
		return;
	}
}

sub getAllStatuses {
	my $self = shift;
    # This logic requires at least one issue in the project to discover transitions/statuses
	my $issues_data = $self->getAllIssues(Project => $self->{project}, Max => 1);
	unless ($issues_data && @{$issues_data->{issues}}) {
        print "Could not find any issues in project '$self->{project}' to determine available statuses.\n";
		return [];
	}
    my $issue_key = $issues_data->{issues}->[0]->{key};

	my $response = $self->{ua}->get($self->{url} . '/rest/api/3/issue/' . $issue_key . '/transitions?expand=transitions.fields');
	
	if ($response->is_success) {
		return \@{decode_json($response->decoded_content)->{transitions}};
	} else {
		print "Error getting statuses (via transitions): " . $response->status_line . "\n";
		return;
	}
}

sub getAllResolutions {
	my $self = shift;
	my $response = $self->{ua}->get($self->{url} . '/rest/api/3/resolution');
	if ($response->is_success) {
		return \@{decode_json($response->decoded_content)};
	} else {
		print "Error getting resolutions: " . $response->status_line . "\n";
		return;
	}
}

sub addWorkLog {
	my $self = shift;
	my %arg = @_;
	my $content = encode_json($arg{WorkLog});

	my @headers = ('Content-Type' => 'application/json');
	if ($arg{Login} && $arg{Password}) {
		my $basic = encode_base64("$arg{Login}:$arg{Password}", '');
		push @headers, 'Authorization' => "Basic $basic";
	}
	
	my $response = $self->{ua}->post(
		$self->{url} . '/rest/api/3/issue/' . $arg{Key} . '/worklog',
		Content => $content,
		@headers
	);
	
	# addWorkLog does not return content on success (201), check status
	return $response->is_success;
}

sub getIssue {
	my $self = shift;
	my %arg = @_;
	my $response = $self->{ua}->get($self->{url} . '/rest/api/3/issue/' . $arg{Key});
	if ($response->is_success) {
		print $response->decoded_content if $self->{verbose};
		return decode_json($response->decoded_content);
	} else {
		print "Error getting issue '$arg{Key}': " . $response->status_line . "\n";
		return;
	}
}

sub deleteIssue {
	my $self = shift;
	my %arg = @_;
	my $response = $self->{ua}->delete($self->{url} . '/rest/api/3/issue/' . $arg{Key});
	if ($response->is_success) {
		print "Issue '$arg{Key}' deleted.\n";
		print $response->status_line . "\n" if $self->{verbose};
		return 1;
	} else {
		print "Error deleting issue '$arg{Key}': " . $response->status_line . "\n";
		return;
	}
}

sub createIssue {
	my $self = shift;
	my %arg = @_;
	my %data;
	$data{fields} = $arg{Issue};
	
	# Enforce Jira character limits (these are safe for v2)
	$data{fields}->{description} = substr($data{fields}->{description}, 0, 32766) if $data{fields}->{description};
	$data{fields}->{summary} = substr($data{fields}->{summary}, 0, 254) if $data{fields}->{summary};
	
    # Sanitize labels (correct for v2)
	if (exists $data{fields}->{labels} && ref $data{fields}->{labels} eq 'ARRAY') {
		$_ =~ s/\s/_/g for @{$data{fields}->{labels}};
	}

	# Map custom field names to their IDs and format data correctly
	foreach my $customField (keys %{$arg{CustomFields}}) {
		my $fieldId = $self->{meta}->{fields}->{$arg{Issue}->{issuetype}->{name}}->{$customField};
		my $fieldType = $self->{meta}->{fieldtypes}->{$customField};
		
		if (defined $fieldId && defined $fieldType) {
			if ($fieldType eq 'string' || $fieldType eq 'datetime') {
				$data{fields}->{$fieldId} = $arg{CustomFields}->{$customField};
			} elsif ($fieldType eq 'option') {
				$data{fields}->{$fieldId} = { value => $arg{CustomFields}->{$customField} };
			} elsif ($fieldType eq 'array') {
				# Assuming array of simple values like components/versions
				$data{fields}->{$fieldId} = [ { name => $arg{CustomFields}->{$customField} } ];
			} elsif ($fieldType eq 'resolution') {
				$data{fields}->{$fieldId} = { name => $arg{CustomFields}->{$customField} };
			} elsif ($fieldType eq 'user') {
				# CHANGE #1: JIRA SERVER/DC (v2) USES 'name' FOR USER PICKERS
				# The original code used 'accountId' for Jira Cloud (v3).
				$data{fields}->{$fieldId} = { name => $arg{CustomFields}->{$customField} };
			}
		}
	}

	my $content = encode_json \%data;
	print "CREATE PAYLOAD: $content\n" if $self->{verbose};
	
	my @headers = ('Content-Type' => 'application/json');
	if ($arg{Login} && $arg{Password}) {
		my $basic = encode_base64("$arg{Login}:$arg{Password}", '');
		push @headers, 'Authorization' => "Basic $basic";
	}


	my $response = $self->{ua}->post($self->{url} . '/rest/api/2/issue', Content => $content, @headers);
	
	if ($response->is_success) {
		my $answer = decode_json($response->decoded_content);
		print "Created issue: $answer->{key}\n" if $self->{verbose};
		return $answer->{key};
	} else {
		print "Error creating issue:\n";
		print $response->status_line . "\n";
		print $response->decoded_content . "\n";
		return;
	}
}

sub changeFields {
	my $self = shift;
	my %arg = @_;
	my %data;


	foreach my $customField (keys %{$arg{Fields}}) {
		my $fieldId = $self->{meta}->{fields}->{Task}->{$customField} || $self->{meta}->{fields}->{Bug}->{$customField};
		my $fieldType = $self->{meta}->{fieldtypes}->{$customField};
		if (defined $fieldId && defined $fieldType) {
			if ($fieldType eq 'string' || $fieldType eq 'datetime') {
				$data{fields}->{$fieldId} = $arg{Fields}->{$customField};
			} elsif ($fieldType eq 'option') {
				$data{fields}->{$fieldId} = { value => $arg{Fields}->{$customField} };
			} elsif ($fieldType eq 'array') {
				$data{fields}->{$fieldId} = [ { name => $arg{Fields}->{$customField} } ];
			} elsif ($fieldType eq 'resolution' || $fieldType eq 'issuetype' || $fieldType eq 'priority') {
				$data{fields}->{$fieldId} = { name => $arg{Fields}->{$customField} };
			} elsif ($fieldType eq 'assignee' || $fieldType eq 'reporter' || $fieldType eq 'user') {
				# JIRA CLOUD REQUIRES accountId
				$data{fields}->{$fieldId} = { accountId => $arg{Fields}->{$customField} };
			}
		}
	}

	my $content = encode_json \%data;
	print "UPDATE PAYLOAD: $content\n" if $self->{verbose};
	
	my @headers = ('Content-Type' => 'application/json');
	if ($arg{Login} && $arg{Password}) {
		my $basic = encode_base64("$arg{Login}:$arg{Password}",'');
		push @headers, 'Authorization' => "Basic $basic";
	}

	my $response = $self->{ua}->put($self->{url} . '/rest/api/3/issue/' . $arg{Key}, Content => $content, @headers);

	if ($response->is_success) {
		print "Fields changed successfully for '$arg{Key}'.\n" if $self->{verbose};
		return 1;
	} else {
		print "Error changing fields for '$arg{Key}':\n";
		print $response->status_line . "\n";
		print $response->decoded_content . "\n";
		return;
	}
}

sub doTransition {
	my $self = shift;
	my %arg = @_;

	# First, find the ID for the desired transition name
	my $transitionId;
	my $get_trans_res = $self->{ua}->get($self->{url} . '/rest/api/3/issue/' . $arg{Key} . '/transitions');
	
	unless ($get_trans_res->is_success) {
		print "Error getting transitions for '$arg{Key}': " . $get_trans_res->status_line . "\n";
		return;
	}
	
	my $answer = decode_json($get_trans_res->decoded_content);
	foreach (@{$answer->{transitions}}) {
		if ($_->{name} eq $arg{Status}) {
			$transitionId = $_->{id};
			print "Transition ID for status '$arg{Status}' is '$transitionId'\n" if $self->{verbose};
			last;
		}
	}

	return unless defined $transitionId;

	my $data = { transition => { id => $transitionId } };
	my $content = encode_json($data);
	print "TRANSITION PAYLOAD: $content\n" if $self->{verbose};
	
	my $post_trans_res = $self->{ua}->post($self->{url} . '/rest/api/3/issue/' . $arg{Key} . '/transitions', 'Content-Type' => 'application/json', Content => $content);
	
	if ($post_trans_res->is_success) {
		print "Transition successful for '$arg{Key}'.\n" if $self->{verbose};
		return 1;
	} else {
		print "Error performing transition on '$arg{Key}':\n";
		print $post_trans_res->status_line . "\n";
		print $post_trans_res->decoded_content . "\n";
		return;
	}
}

sub createIssues {
	my $self = shift;
	my %arg = @_;
	my %data;
	
	foreach (@{$arg{Issues}}) {
		push @{$data{issueUpdates}}, { fields => $_ };
	}
	
	my $content = encode_json \%data;
	print "BULK CREATE PAYLOAD: $content\n" if $self->{verbose};
	my $response = $self->{ua}->post($self->{url} . '/rest/api/3/issue/bulk', 'Content-Type' => 'application/json', Content => $content);
	
	if ($response->is_success) {
		print "Bulk issue creation successful.\n" if $self->{verbose};
		print $response->decoded_content . "\n" if $self->{verbose};
		return decode_json($response->decoded_content);
	} else {
		print "Error during bulk issue creation:\n";
		print $response->status_line . "\n";
		print $response->decoded_content . "\n";
		return;
	}
}

sub createComment {
	my $self = shift;
	my %arg = @_;
	
	my $data = {
		body => {
			type => 'doc',
			version => 1,
			content => [
				{
					type => 'paragraph',
					content => [
						{
							type => 'text',
							text => substr($arg{Body}, 0, 32766)
						}
					]
				}
			]
		}
	};
	

	my $content = encode_json($data);
	print "COMMENT PAYLOAD: $content\n" if $self->{verbose};


	my @headers = ('Content-Type' => 'application/json');
	if ($arg{Login} && $arg{Password}) {
		my $basic = encode_base64("$arg{Login}:$arg{Password}", '');
		push @headers, 'Authorization' => "Basic $basic";
	}
	
	my $response = $self->{ua}->post($self->{url} . '/rest/api/3/issue/' . $arg{IssueKey} . '/comment', Content => $content, @headers);
	
	if ($response->is_success) {
		return decode_json($response->decoded_content);
	} else {
		print "Error creating comment on '$arg{IssueKey}':\n";
		print $response->status_line . "\n";
		print $response->decoded_content . "\n";
		return;
	}
}

sub createIssueLink {
	my $self = shift;
	my %arg = @_;
	my $content = encode_json($arg{Link});
	print "LINK PAYLOAD: $content\n" if $self->{verbose};
	
	my $response = $self->{ua}->post($self->{url} . '/rest/api/3/issueLink', 'Content-Type' => 'application/json', Content => $content);
	
	if ($response->is_success) {
		print "Issue link created successfully.\n" if $self->{verbose};
		return 1;
	} else {
		print "Error creating issue link: " . $response->status_line . "\n";
		return;
	}
}


sub addAttachments {
	my $self = shift;
	my %arg = @_;
	
	# Loop through each file path provided
	foreach my $file (@{$arg{Files}}) {
		unless (-f $file) {
			warn "Attachment file not found: $file\n";
			next; # Skip to the next file
		}
		
		my $filesize = -s $file;
		if ($filesize > 10485760) { # Default Jira attachment limit is 10MB
			warn "File '$file' exceeds the maximum size of 10MB and will be skipped.\n";
			next; # Skip to the next file
		}

   
		my $url = $self->{url} . '/rest/api/3/issue/' . $arg{IssueKey} . '/attachments';

		
		my $req = POST(
			$url,
			Content_Type => 'multipart/form-data',
			Content      => [ file => [$file] ] # The 'file' key is what Jira's API expects
		);
		

		$req->header('X-Atlassian-Token' => 'no-check');
		if ($arg{Login} && $arg{Password}) {
			my $basic = $arg{Base64};
		}

		
		
		print "Uploading '$file' to '$arg{IssueKey}'...\n" if $self->{verbose};
		my $response = $self->{ua}->request($req);
		
		if ($response->is_success) {
			print "Attachment '$file' uploaded successfully.\n" if $self->{verbose};
		} else {
			warn "Error uploading attachment '$file' to '$arg{IssueKey}':\n";
			warn $response->status_line . "\n";
			warn $response->decoded_content . "\n";
			return; # Stop on the first error
		}
	}
	
	return 1; # Return 1 to indicate all files were processed successfully
}

1;
