# The warm-up's traffic: what a person does in eShopLegacyMVC's catalog manager, as
# scenarios. Dot-sourced by 3-record-eshop.ps1; defines functions only.
#
# One scenario is one browser session (one cookie jar) and becomes one replayed session:
# `sk replay` restarts the application before each one (Reset-EShop.ps1), so every
# scenario starts from the same 12-item catalog, whatever the one before it changed.
#
# Sample data (eShopLegacyMVC\Models\Infrastructure\PreconfiguredData.cs at the pinned
# commit): item 1 ".NET Bot Black Hoodie" $19.50, item 2 ".NET Black & White Mug" $8.50,
# item 3 "Prism White T-Shirt" $12.00, item 9 "Cup<T> White Mug", item 11 "Cup<T> Sheet";
# brands 1-5 (2 is ".NET"), types 1-4 (1 is "Mug").

function Get-EShopScenario {
    $list = New-Object System.Collections.Generic.List[object]

    $list.Add([pscustomobject]@{ Id = 'E01'; Title = 'Browse the catalog: pages, details, a picture'; Run = {
                param($s)
                $null = Invoke-BenchStep -Session $s -Path '/' -MustContain @('Showing 10 of 12 products - Page 1 - 2', '.NET Bot Black Hoodie')
                $null = Invoke-BenchStep -Session $s -Path '/?pageSize=10&pageIndex=1' -MustContain @('Page 2 - 2', 'Cup&lt;T&gt; Sheet')
                $null = Invoke-BenchStep -Session $s -Path '/?pageSize=5&pageIndex=2' -MustContain @('Showing 5 of 12 products - Page 3 - 3')
                $null = Invoke-BenchStep -Session $s -Path '/Catalog/Details/1' -MustContain @('.NET Bot Black Hoodie', '$19.50')
                $null = Invoke-BenchStep -Session $s -Path '/Catalog/Details/9' -MustContain @('Cup&lt;T&gt; White Mug')
                $null = Invoke-BenchStep -Session $s -Path '/items/1/pic' -ExpectContentType 'image/png'
            }
        })

    $list.Add([pscustomobject]@{ Id = 'E02'; Title = 'Items that do not exist, and a details link without an id'; Run = {
                param($s)
                $null = Invoke-BenchStep -Session $s -Path '/Catalog/Details/999' -ExpectStatus @(404)
                $null = Invoke-BenchStep -Session $s -Path '/Catalog/Edit/999' -ExpectStatus @(404)
                $null = Invoke-BenchStep -Session $s -Path '/Catalog/Delete/999' -ExpectStatus @(404)
                $null = Invoke-BenchStep -Session $s -Path '/Catalog/Details' -ExpectStatus @(400)
            }
        })

    $list.Add([pscustomobject]@{ Id = 'E03'; Title = 'Create an item; it is listed and has its own page'; Run = {
                param($s)
                $page = Invoke-BenchStep -Session $s -Path '/Catalog/Create' -MustContain @('__RequestVerificationToken')
                $form = Get-BenchForm -Html $page.Body -FormPattern 'action="/Catalog/Create"'
                Set-BenchFormField -Fields $form -Name 'Name' -Value 'Bench Mug'
                Set-BenchFormField -Fields $form -Name 'Description' -Value 'Recorded by the bench'
                Set-BenchFormField -Fields $form -Name 'CatalogBrandId' -Value '2'
                Set-BenchFormField -Fields $form -Name 'CatalogTypeId' -Value '1'
                Set-BenchFormField -Fields $form -Name 'Price' -Value '9.99'
                Set-BenchFormField -Fields $form -Name 'AvailableStock' -Value '7'
                Set-BenchFormField -Fields $form -Name 'RestockThreshold' -Value '1'
                Set-BenchFormField -Fields $form -Name 'MaxStockThreshold' -Value '20'
                $null = Invoke-BenchStep -Session $s -Path '/Catalog/Create' -Method POST -FormPairs $form -ExpectStatus @(302) -ExpectLocation '^/$'
                $null = Invoke-BenchStep -Session $s -Path '/?pageSize=10&pageIndex=1' -MustContain @('Showing 10 of 13 products', 'Bench Mug')
                $null = Invoke-BenchStep -Session $s -Path '/Catalog/Details/13' -MustContain @('Bench Mug', '$9.99')
            }
        })

    $list.Add([pscustomobject]@{ Id = 'E04'; Title = 'A create with invalid values is refused, with the reasons'; Run = {
                param($s)
                $page = Invoke-BenchStep -Session $s -Path '/Catalog/Create'
                $form = Get-BenchForm -Html $page.Body -FormPattern 'action="/Catalog/Create"'
                Set-BenchFormField -Fields $form -Name 'Name' -Value ''
                Set-BenchFormField -Fields $form -Name 'Price' -Value '12.345'
                Set-BenchFormField -Fields $form -Name 'AvailableStock' -Value '-1'
                $null = Invoke-BenchStep -Session $s -Path '/Catalog/Create' -Method POST -FormPairs $form -MustContain @('The Name field is required.', 'The field Price must be a positive number with maximum two decimals.', 'The field Stock must be between 0 and 10 million.')
                $null = Invoke-BenchStep -Session $s -Path '/?pageSize=10&pageIndex=1' -MustContain @('Showing 10 of 12 products')
            }
        })

    $list.Add([pscustomobject]@{ Id = 'E05'; Title = 'Edit an item''s price'; Run = {
                param($s)
                $page = Invoke-BenchStep -Session $s -Path '/Catalog/Edit/2' -MustContain @('.NET Black &amp; White Mug')
                $form = Get-BenchForm -Html $page.Body -FormPattern 'action="/Catalog/Edit/2"'
                Set-BenchFormField -Fields $form -Name 'Price' -Value '10.50'
                $null = Invoke-BenchStep -Session $s -Path '/Catalog/Edit/2' -Method POST -FormPairs $form -ExpectStatus @(302) -ExpectLocation '^/$'
                $null = Invoke-BenchStep -Session $s -Path '/Catalog/Details/2' -MustContain @('.NET Black &amp; White Mug', '$10.50')
            }
        })

    $list.Add([pscustomobject]@{ Id = 'E06'; Title = 'Delete an item; it is gone from the list and its page'; Run = {
                param($s)
                $page = Invoke-BenchStep -Session $s -Path '/Catalog/Delete/3' -MustContain @('Are you sure you want to delete this?', 'Prism White T-Shirt')
                $form = Get-BenchForm -Html $page.Body -FormPattern 'action="/Catalog/Delete/3"'
                $null = Invoke-BenchStep -Session $s -Path '/Catalog/Delete/3' -Method POST -FormPairs $form -ExpectStatus @(302) -ExpectLocation '^/$'
                $null = Invoke-BenchStep -Session $s -Path '/Catalog/Details/3' -ExpectStatus @(404)
                $null = Invoke-BenchStep -Session $s -Path '/?pageSize=12&pageIndex=0' -MustContain @('Showing 12 of 11 products') -MustNotContain @('Prism White T-Shirt')
            }
        })

    $list.Add([pscustomobject]@{ Id = 'E07'; Title = 'The brands Web API'; Run = {
                param($s)
                $null = Invoke-BenchStep -Session $s -Path '/api/brands' -ExpectContentType 'application/json' -MustContain @('"Brand":".NET"')
                $null = Invoke-BenchStep -Session $s -Path '/api/brands/2' -ExpectContentType 'application/json' -MustContain @('"Id":2')
                $null = Invoke-BenchStep -Session $s -Path '/api/brands/42' -ExpectStatus @(404)
            }
        })

    return , $list
}
